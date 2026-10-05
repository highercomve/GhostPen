//! A web page for the summarizer: fetch a URL and pull the readable text
//! out of the HTML (no rendering, no dependencies: the articles the menu's
//! "Summarize link" reads are plain HTML).
//!
//! The extraction is deliberately dumber than a reader mode: scripts,
//! styles, chrome (nav/header/footer/aside) and attributes are dropped,
//! block tags become paragraph breaks, entities are decoded and runs of
//! whitespace collapse. What reaches the model is one plain-text document
//! plus the page's title.

const std = @import("std");

/// Ten seconds for a page: articles are small, and waiting is the worst
/// part of a failed read.
const fetch_timeout_ms = 10_000;
/// The document text cap fed to the model (about 30k tokens).
const max_text_bytes = 120_000;

pub const Page = struct {
    title: []const u8,
    text: []const u8,

    /// The document as one prompt block: the title first, then the body.
    pub fn prompt(self: Page, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "Document: {s}\n\n{s}", .{ self.title, self.text });
    }
};

/// The summary's depth: the picker in the summary window.
pub const Level = enum { brief, standard, detailed };

/// `args.level` (a string over the protocol) as a `Level`; the default is
/// the shape the summarizer launched with.
pub fn parseLevel(level: ?[]const u8) Level {
    return std.meta.stringToEnum(Level, level orelse "standard") orelse .standard;
}

/// The summary prompt for `level`: what the model reads the document with.
/// It writes Markdown (the summary window renders it), so the shapes it
/// uses are the ones the renderer handles: headings, lists, quotes, bold.
pub fn summaryPrompt(arena: std.mem.Allocator, level: Level) ![]const u8 {
    const honesty =
        \\You summarize web documents for a reader who clicked a link.
        \\Work only from the document you are given: never invent facts,
        \\numbers or names, and when the document doesn't say something, say
        \\so in one short sentence instead of filling the gap.
        \\Answer ONLY the summary itself, in clean Markdown, in this shape:
    ;
    const etiquette =
        \\Use **bold** sparingly, only for the few names worth scanning for.
        \\No preamble ("Here is..."), no closing question to the reader.
    ;
    const shape: []const u8 = switch (level) {
        .brief =>
        \\- An opening paragraph (2-3 sentences): what this is and what
        \\  makes it worth reading — the whole thing in a nutshell.
        \\- A `## Key points` heading with 3-5 bullets, one line each, only
        \\  the concrete facts (names, numbers, prices, dates).
        \\Nothing else: no Details section, no quotes, no closing.
        ,
        .standard =>
        \\- An opening paragraph (2-3 sentences): what this is and what makes
        \\  it worth reading.
        \\- A `## Key points` heading with a compact bulleted list, one line
        \\  per point, the concrete facts.
        \\- A `## Details` heading with 2-5 short paragraphs (or short
        \\  sub-lists) following the document's own order.
        \\- At most two quoted sentences, as `> quote` lines, when a line is
        \\  worth reading exactly as written.
        ,
        .detailed =>
        \\- An opening paragraph (2-3 sentences): what this is and what makes
        \\  it worth reading.
        \\- A `## Key points` heading with a compact bulleted list (5-8
        \\  points, one line each), the concrete facts.
        \\- A `## Details` heading with 4-8 short paragraphs (or short
        \\  sub-lists) following the document's own order, keeping its
        \\  numbers, prices, dates and names.
        \\- Up to three quoted sentences, as `> quote` lines, when a line is
        \\  worth reading exactly as written.
        ,
    };
    return std.fmt.allocPrint(arena, "{s}\n{s}\n{s}", .{ honesty, shape, etiquette });
}

pub const Diag = struct { message: []const u8 = "" };
pub const Error = error{AiFailed} || std.mem.Allocator.Error;

/// Fetch `url` (HTTP or HTTPS) and extract the document; `diag` carries a
/// user-facing phrase on failure.
pub fn read(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, diag: *Diag) Error!Page {
    if (std.mem.startsWith(u8, url, "//")) {
        return diagFail(arena, diag, "Links need a scheme (https://...).", .{});
    }
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return diagFail(arena, diag, "This doesn't look like a web link: it must start with https://.", .{});
    }

    var html_buf: std.Io.Writer.Allocating = .init(gpa);
    defer html_buf.deinit();
    const status = try fetch(io, gpa, url, &html_buf.writer, diag);
    switch (status) {
        .ok, .moved_permanently, .found, .multiple_choice => {},
        .not_found => return diagFail(arena, diag, "The page doesn't exist (404): is the link right?", .{}),
        .forbidden, .unauthorized => return diagFail(arena, diag, "The site refuses automated readers (401/403): open the page in a browser and copy its text here instead.", .{}),
        .too_many_requests => return diagFail(arena, diag, "The site asked to slow down (429): try again in a minute.", .{}),
        else => return diagFail(arena, diag, "The site answered with HTTP {d}.", .{@intFromEnum(status)}),
    }
    const html = html_buf.written();
    if (html.len == 0) return diagFail(arena, diag, "The site answered with an empty page.", .{});
    return extract(arena, html) catch return diagFail(arena, diag, "Could not read the page's text.", .{});
}

fn diagFail(arena: std.mem.Allocator, diag: *Diag, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.AiFailed;
}

const Timeout = struct {
    fn sleep(i: std.Io, ms: u32) void {
        i.sleep(.fromMilliseconds(ms), .awake) catch {};
    }
};

fn fetch(io: std.Io, gpa: std.mem.Allocator, url: []const u8, sink: *std.Io.Writer, diag: *Diag) Error!std.http.Status {
    const Fetch = struct {
        fn run(i: std.Io, alloc: std.mem.Allocator, u: []const u8, w: *std.Io.Writer) anyerror!std.http.Status {
            var client: std.http.Client = .{ .allocator = alloc, .io = i };
            defer client.deinit();
            const res = try client.fetch(.{
                .location = .{ .url = u },
                .keep_alive = false,
                .headers = .{
                    .accept_encoding = .{ .override = "identity" },
                    .user_agent = .{ .override = "Mozilla/5.0 (X11; Linux x86_64) GhostPen/2.19" },
                },
                .response_writer = w,
            });
            return res.status;
        }
    };
    const Outcome = union(enum) { done: anyerror!std.http.Status, timeout: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, Fetch.run, .{ io, gpa, url, sink }) catch return diagFail(gpa, diag, "Could not start the request.", .{});
    // The fetch points into this frame: never return while it may still run.
    sel.concurrent(.timeout, Timeout.sleep, .{ io, fetch_timeout_ms }) catch {
        sel.cancelDiscard();
        return diagFail(gpa, diag, "Could not start the request.", .{});
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        return diagFail(gpa, diag, "Request cancelled.", .{});
    };
    sel.cancelDiscard();
    return switch (first) {
        .timeout => diagFail(gpa, diag, "The page took too long (10 s): is the site reachable?", .{}),
        .done => |r| r catch |err| switch (err) {
            error.ConnectionRefused, error.UnknownHostName, error.NetworkUnreachable, error.HostUnreachable, error.ConnectionResetByPeer, error.ConnectionTimedOut => diagFail(gpa, diag, "Could not connect to the site.", .{}),
            error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat, error.UnexpectedCharacter, error.InvalidPort => diagFail(gpa, diag, "The link is not valid.", .{}),
            error.OutOfMemory => error.OutOfMemory,
            else => diagFail(gpa, diag, "The request failed ({s}).", .{@errorName(err)}),
        },
    };
}

// ---- the HTML-to-text extraction --------------------------------------------------------

/// The tags whose whole region is skipped (from `<tag` to the matching
/// `</tag`): active content, embeds and the page's chrome. (Not the head:
/// its walk is harmless and <title> is in it; not the header: articles put
/// their h1 there. Void elements — input, source, embed, img, meta — have
/// no close tag and must never be here.)
const skip_tags = [_][]const u8{ "script", "style", "svg", "template", "noscript", "iframe", "object", "form", "select", "option", "textarea", "button", "label", "video", "audio", "picture", "nav", "footer", "aside" };
/// The tags that end a paragraph (their closing tag emits a blank line).
const para_tags = [_][]const u8{ "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "table", "dd", "dt", "dl", "blockquote", "section", "article", "figure", "figcaption", "main", "pre", "details", "summary", "hr" };
/// Which tags emit which separators, on which side.
const Kind = enum { none, inline_sep, soft, para };
const Sides = struct { open: Kind = .none, close: Kind = .none };

fn sidesFor(name: []const u8) Sides {
    // void elements open on their own; the rest break when they close.
    if (std.mem.eql(u8, name, "br")) return .{ .open = .soft };
    if (std.mem.eql(u8, name, "tr")) return .{ .close = .soft };
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') return .{ .close = .para };
    for (para_tags) |t| {
        if (std.mem.eql(u8, t, name)) return .{ .close = .para };
    }
    return .{ .open = .inline_sep, .close = .inline_sep };
}

fn inList(comptime list: []const []const u8, name: []const u8) bool {
    inline for (list) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Text runs hold no '<', so this sentinel is free to direct whitespace.
const sep: u8 = 0;

/// The document: the page's title (or a stand-in) and the body text.
pub fn extract(arena: std.mem.Allocator, html: []const u8) !Page {
    var body = std.Io.Writer.Allocating.init(arena);
    var title = std.Io.Writer.Allocating.init(arena);

    var i: usize = 0;
    var in_title = false;
    while (i < html.len) {
        const c = html[i];
        if (c != '<') {
            // A text run: entities decoded on the way into its buffer.
            const run_end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            const run = html[i..run_end];
            if (in_title) {
                _ = try decode(run, &title.writer);
            } else if (!isBlank(run)) {
                _ = try decode(run, &body.writer);
            }
            i = run_end;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |e| e + 3 else break;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!")) {
            i = if (std.mem.indexOfScalarPos(u8, html, i, '>')) |e| e + 1 else break;
            continue;
        }
        // The tag's name.
        var j = i + 1;
        if (j < html.len and html[j] == '/') j += 1;
        const name_start = j;
        while (j < html.len and std.ascii.isAlphanumeric(html[j])) : (j += 1) {}
        const name = html[name_start..j];
        if (name.len == 0) {
            // A stray '<' in text.
            (if (in_title) &title.writer else &body.writer).writeByte('<') catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const closing = i + 1 < html.len and html[i + 1] == '/';
        // Skipped regions: to the matching close (the literal; script bodies
        // contain '>' freely, so searching for it would not do).
        if (!closing and inList(&skip_tags, name)) {
            var close_buf: [16]u8 = undefined;
            const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch unreachable;
            i = findClose(html, j, close) orelse html.len;
            continue;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, html, j, '>') orelse break;
        if (std.mem.eql(u8, name, "title")) {
            in_title = !closing;
            i = tag_end + 1;
            continue;
        }
        const sides = sidesFor(name);
        const kind: Kind = if (closing) sides.close else sides.open;
        switch (kind) {
            .none => {},
            .inline_sep => body.writer.writeByte(sep) catch return error.OutOfMemory,
            .soft, .para => {
                body.writer.writeByte('\n') catch return error.OutOfMemory;
                if (kind == .para) body.writer.writeByte('\n') catch return error.OutOfMemory;
            },
        }
        i = tag_end + 1;
    }

    // Collapse: words one space apart, paragraphs each their line, extra
    // gaps capped at one blank line.
    var final = std.Io.Writer.Allocating.init(arena);
    var blanks: usize = 0;
    var line: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body.written(), '\n');
    while (lines.next()) |line_raw| {
        line.clearRetainingCapacity();
        var words = false;
        var words_it = std.mem.tokenizeAny(u8, line_raw, " \t\r\x0b\x0c" ++ [_]u8{sep});
        while (words_it.next()) |word| {
            if (words) line.append(arena, ' ') catch return error.OutOfMemory;
            line.appendSlice(arena, word) catch return error.OutOfMemory;
            words = true;
        }
        if (line.items.len == 0) {
            if (final.written().len > 0) blanks += 1;
            continue;
        }
        for (0..@min(blanks + 1, 2)) |_| final.writer.writeByte('\n') catch return error.OutOfMemory;
        blanks = 0;
        final.writer.writeAll(line.items) catch return error.OutOfMemory;
    }
    var text = std.mem.trim(u8, final.written(), "\n ");
    if (text.len > max_text_bytes) {
        const head = text[0..max_text_bytes];
        text = if (std.mem.lastIndexOfScalar(u8, head, '\n')) |cut| head[0..cut] else head;
        text = std.mem.trim(u8, text, "\n ");
    }

    const title_raw = std.mem.trim(u8, title.written(), " \t\r\n");
    const final_title: []const u8 = blk: {
        if (title_raw.len > 0) break :blk title_raw;
        if (text.len > 0) {
            if (firstHost(arena, text)) |h| break :blk h;
        }
        break :blk "The page";
    };
    return .{ .title = final_title, .text = text };
}

fn isBlank(run: []const u8) bool {
    for (run) |c| switch (c) {
        ' ', '\t', '\r', '\n', 0xa0 => {},
        else => return false,
    };
    return true;
}

/// The first http(s)://... host in the text: a title fallback that still
/// points somewhere.
fn firstHost(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "://") orelse return null;
    const start = if (at < 8) 0 else std.mem.lastIndexOfAny(u8, text[0..at], " \n\t") orelse 0;
    var end: usize = @min(at + 4, text.len);
    while (end < text.len and text[end] != ' ' and text[end] != '\n' and text[end] != '\t') : (end += 1) {}
    const full = text[start..end];
    const host = if (std.mem.indexOf(u8, full, "//")) |s| full[@min(s + 2, full.len)..] else full;
    const cut = std.mem.indexOfScalar(u8, host, '/') orelse host.len;
    return arena.dupe(u8, host[0..cut]) catch null;
}

/// Case-insensitive search for a `</script`-style close, from `from`.
fn findClose(html: []const u8, from: usize, close: []const u8) ?usize {
    var i = from;
    while (i + close.len <= html.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(html[i .. i + close.len], close)) return i;
    }
    return null;
}

/// A text run with its entities decoded straight into `w`; returns how
/// many entities were decoded (0: nothing to do).
fn decode(run: []const u8, w: *std.Io.Writer) !usize {
    var wrote: usize = 0;
    var i: usize = 0;
    while (i < run.len) {
        const amp = std.mem.indexOfScalarPos(u8, run, i, '&') orelse {
            w.writeAll(run[i..]) catch return error.OutOfMemory;
            break;
        };
        w.writeAll(run[i..amp]) catch return error.OutOfMemory;
        i = amp + 1;
        const semi = std.mem.indexOfScalarPos(u8, run, i, ';') orelse {
            w.writeByte('&') catch return error.OutOfMemory;
            continue;
        };
        if (semi == i or semi > i + 12) {
            // Not entity-shaped: the '&' is literal text.
            w.writeByte('&') catch return error.OutOfMemory;
            continue;
        }
        const name = run[i..semi];
        const numeric = name.len > 1 and name[0] == '#';
        if (!numeric and entityValue(name) == null) {
            // Unknown entity: the '&' is literal; what follows reads on as
            // ordinary text (the same bytes, but no later entity hides
            // inside an unknown one).
            w.writeByte('&') catch return error.OutOfMemory;
            continue;
        }
        if (numeric) {
            const codepoint: u21 = blk: {
                if (name.len > 2 and (name[1] == 'x' or name[1] == 'X')) {
                    break :blk std.fmt.parseInt(u21, name[2..], 16) catch 0;
                }
                break :blk std.fmt.parseInt(u21, name[1..], 10) catch 0;
            };
            if (codepoint != 0) {
                var utf8_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                    w.writeByte('&') catch return error.OutOfMemory;
                    continue;
                };
                w.writeAll(utf8_buf[0..n]) catch return error.OutOfMemory;
                wrote += 1;
                i = semi + 1;
                continue;
            }
        } else {
            // A named entity in the table.
            w.writeAll(entityValue(name) orelse "") catch return error.OutOfMemory;
            wrote += 1;
            i = semi + 1;
            continue;
        }
        // A numeric escape we couldn't decode: literal '&'.
        w.writeByte('&') catch return error.OutOfMemory;
    }
    return wrote;
}

const entity_pairs = [_]struct { n: []const u8, v: []const u8 }{
    .{ .n = "amp", .v = "&" },
    .{ .n = "lt", .v = "<" },
    .{ .n = "gt", .v = ">" },
    .{ .n = "quot", .v = "\"" },
    .{ .n = "apos", .v = "'" },
    .{ .n = "nbsp", .v = " " },
    .{ .n = "ndash", .v = "\u{2013}" },
    .{ .n = "mdash", .v = "\u{2014}" },
    .{ .n = "hellip", .v = "\u{2026}" },
    .{ .n = "rsquo", .v = "\u{2019}" },
    .{ .n = "lsquo", .v = "\u{2018}" },
    .{ .n = "ldquo", .v = "\u{201c}" },
    .{ .n = "rdquo", .v = "\u{201d}" },
    .{ .n = "copy", .v = "\u{00a9}" },
    .{ .n = "reg", .v = "\u{00ae}" },
    .{ .n = "trade", .v = "\u{2122}" },
    .{ .n = "times", .v = "\u{00d7}" },
    .{ .n = "middot", .v = "\u{00b7}" },
    .{ .n = "laquo", .v = "\u{00ab}" },
    .{ .n = "raquo", .v = "\u{00bb}" },
    .{ .n = "deg", .v = "\u{00b0}" },
    .{ .n = "eacute", .v = "\u{00e9}" },
    .{ .n = "egrave", .v = "\u{00e8}" },
    .{ .n = "aacute", .v = "\u{00e1}" },
    .{ .n = "uacute", .v = "\u{00fa}" },
};

fn entityValue(name: []const u8) ?[]const u8 {
    for (entity_pairs) |p| {
        if (std.mem.eql(u8, p.n, name)) return p.v;
    }
    return null;
}

test "article extraction: title, chrome, entities and paragraphs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<title>I went hands-on with Google Books &mdash; a review</title>
        \\<script>let o = { a: 1 };</script>
        \\<style>.x { color: red }</style></head><body>
        \\<nav>Menu Home About Apps Games Downloads</nav>
        \\<h1>I went hands-on with Google&mdash;books&hellip;</h1>
        \\<p>First paragraph &quot;quoted&quot; with an <a href="/x">important link</a> inside.</p>
        \\<div>Second block<br />with a break</div>
        \\<!-- the comment's text never shows -->
        \\<p>Third</p>
        \\<p>&amp;&lt;&gt;&#39;&#x201C;unicode&#x201D;</p>
        \\<footer>Privacy &middot; Terms &middot; (c) site</footer>
    ;
    const page = try extract(arena, html);
    try std.testing.expectEqualStrings("I went hands-on with Google Books \u{2014} a review", page.title);
    try std.testing.expectEqualStrings(
        "I went hands-on with Google\u{2014}books\u{2026}\n\nFirst paragraph \"quoted\" with an important link inside.\n\nSecond block\nwith a break\n\nThird\n\n&<>'\u{201c}unicode\u{201d}",
        page.text,
    );
}

test "a title-less page falls back to the first link's host" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = try extract(arena, "<div>No title here</div><p>first https://example.com/docs/article one</p>");
    try std.testing.expectEqualStrings("example.com", page.title);
    try std.testing.expectEqualStrings("No title here\n\nfirst https://example.com/docs/article one", page.text);
}

test "entities decode, unknown ones stay" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.testing.expectEqual(@as(usize, 0), try decode("plain words", &w));
    try std.testing.expectEqualStrings("plain words", buf[0..w.end]);
    w.end = 0;
    try std.testing.expectEqual(@as(usize, 2), try decode("a&amp;b&gt;c", &w));
    try std.testing.expectEqualStrings("a&b>c", buf[0..w.end]);
    w.end = 0;
    _ = try decode("&weirdname; &notreally &#xzz &#38;", &w);
    try std.testing.expectEqualStrings("&weirdname; &notreally &#xzz &", buf[0..w.end]);
}
