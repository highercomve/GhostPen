//! A minimal PDF writer for the summarizer's "Export to PDF": the summary's
//! Markdown subset (headings, paragraphs, nested lists, block quotes,
//! fenced code, rules) laid out on A4 pages with the PDF base-14 fonts, so
//! no font is embedded and the file opens everywhere. Rendered Mermaid
//! diagrams embed as JPEGs; oversized drawings span overlapping panels.
//!
//! Line widths come from a per-character estimate (Courier's 0.6 per glyph
//! is exact; the proportional faces get pessimistic class estimates), which
//! keeps every wrapped line inside the margins. Pages break where they end;
//! each page's number prints at its foot.

const std = @import("std");

const page_w: f32 = 595.28; // A4, in points
const page_h: f32 = 841.89;
const margin: f32 = 57;
const foot: f32 = 38; // the page number's baseline
const text_w: f32 = page_w - 2 * margin;

pub const Options = struct {
    /// The document title (the summary's title); "Summary" when empty.
    title: []const u8,
    /// Under the title, e.g. "GhostPen summary · 2026-10-20".
    subtitle: []const u8 = "",
    /// The summary's Markdown (the same text Copy copies).
    markdown: []const u8,
    /// Rendered diagrams: a ```mermaid fence whose source is one of these
    /// keys embeds the JPEG; the rest stay readable code blocks.
    images: []const Image = &.{},
};

/// One diagram: `jpeg` is the image as base64 (whatever the page's
/// canvas.toDataURL('image/jpeg') yields after the prefix).
pub const Image = struct {
    key: []const u8,
    jpeg: []const u8,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Error = error{OutOfMemory};

/// The summary as a PDF file, allocated with `arena`.
pub fn render(arena: std.mem.Allocator, opts: Options) Error![]const u8 {
    var doc = Doc.init(arena);
    var images: std.ArrayList(Image) = .empty;
    for (opts.images) |image| {
        if (validImageDimensions(image)) try images.append(arena, image);
    }
    doc.images = images.items;
    try doc.titlePage(opts.title, opts.subtitle);
    var prev: ?Block.Kind = null;
    const content = try blocks(arena, opts.markdown, doc.images);
    for (content, 0..) |b, i| {
        switch (b.kind) {
            .heading => {
                try doc.keepHeading(b, if (i + 1 < content.len) content[i + 1] else null);
                try doc.gap(if (prev == null) 0 else 15);
                try doc.heading(b.text, b.level);
                try doc.gap(5);
            },
            .rule => {
                try doc.gap(8);
                try doc.rule();
                try doc.gap(10);
            },
            .para => {
                try doc.gap(5);
                try doc.flowing(b.text, .body, 11, 16.5, 0, "");
            },
            .quote => {
                try doc.gap(6);
                try doc.quote(b.text);
            },
            .list => {
                try doc.gap(if (prev == .list) 2 else 6);
                try doc.flowing(b.text, .body, 11, 16.5, 10 + @as(f32, @floatFromInt(b.level)) * 14, b.marker);
            },
            .image => {
                try doc.gap(8);
                try doc.imageBlock(b);
                try doc.gap(12);
            },
            .code => {
                try doc.gap(8);
                try doc.codeBlock(b.text);
                try doc.gap(10);
            },
        }
        prev = b.kind;
    }
    return try doc.finish();
}

/// Test hooks.
pub fn blocksForTesting(arena: std.mem.Allocator, markdown: []const u8) Error![]Block {
    return blocks(arena, markdown, &.{});
}

// ---- the Markdown subset ----------------------------------------------------------------

const Block = struct {
    kind: Kind,
    /// List items: the marker as written ("•", "·", "5."); others empty.
    marker: []const u8 = "",
    /// Headings: 1-3 (deeper ones flatten); lists: the nesting depth (0-3).
    level: u8 = 0,
    text: []const u8,
    /// An image block: the embedded JPEG (decoded), its size in samples
    /// and the object number it went into.
    image: EmbeddedImage = .{},

    const Kind = enum { heading, para, list, quote, code, rule, image };
};

const EmbeddedImage = struct {
    jpeg: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Its XObject number (the images' objects start at 7, in the order
    /// they came in the options).
    object: usize = 0,
    /// The XObject name to draw with (/Im0, /Im1...).
    name: []const u8 = "Im0",
};

fn blocks(arena: std.mem.Allocator, markdown: []const u8, images: []const Image) Error![]Block {
    var out: std.ArrayList(Block) = .empty;
    const lines = try std.mem.replaceOwned(u8, arena, markdown, "\r\n", "\n");

    var para: std.ArrayList(u8) = .empty;
    var quote: std.ArrayList(u8) = .empty;
    var fence: ?std.ArrayList(u8) = null;

    // A closed accumulated run (a paragraph or a quote) becomes a block,
    // with its inline markers cleared.
    const gather = struct {
        fn one(o: *std.ArrayList(Block), a: std.mem.Allocator, ran: []const u8, k: Block.Kind) Error!void {
            if (std.mem.trim(u8, ran, " ").len == 0) return;
            try o.append(a, .{ .kind = k, .text = try plain(a, ran) });
        }
    };
    const drop = struct {
        fn both(o: *std.ArrayList(Block), a: std.mem.Allocator, para_: *std.ArrayList(u8), quote_: *std.ArrayList(u8)) Error!void {
            try gather.one(o, a, para_.items, .para);
            try gather.one(o, a, quote_.items, .quote);
            para_.clearRetainingCapacity();
            quote_.clearRetainingCapacity();
        }
    };

    var split = std.mem.splitScalar(u8, lines, '\n');
    var fence_mermaid = false;
    while (split.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        // Fenced code: on until the matching fence (all or nothing).
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            if (fence) |f| {
                if (f.items.len > 0) {
                    const crop = f.items[0 .. f.items.len - 1];
                    if (fence_mermaid) {
                        if (matched(arena, images, crop)) |img| {
                            try out.append(arena, .{ .kind = .image, .image = img, .text = "" });
                            fence = null;
                            fence_mermaid = false;
                            continue;
                        }
                    }
                    try out.append(arena, .{ .kind = .code, .text = try arena.dupe(u8, crop) });
                }
                fence = null;
                fence_mermaid = false;
            } else {
                try drop.both(&out, arena, &para, &quote);
                fence = .empty;
                var info = std.mem.tokenizeAny(u8, trimmed[3..], " \t");
                fence_mermaid = std.ascii.eqlIgnoreCase(info.next() orelse "", "mermaid");
            }
            continue;
        }
        if (fence != null) {
            try fence.?.appendSlice(arena, raw);
            try fence.?.append(arena, '\n');
            continue;
        }

        if (headingOf(raw)) |level| {
            try drop.both(&out, arena, &para, &quote);
            try out.append(arena, .{
                .kind = .heading,
                .level = @min(level, 3),
                .text = try plain(arena, raw[1 + level ..]),
            });
            continue;
        }

        if (isRule(raw)) {
            try drop.both(&out, arena, &para, &quote);
            try out.append(arena, .{ .kind = .rule, .text = "" });
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            try gather.one(&out, arena, para.items, .para);
            para.clearRetainingCapacity();
            try quote.appendSlice(arena, std.mem.trimStart(u8, trimmed[1..], " "));
            try quote.append(arena, ' ');
            continue;
        }

        if (listOf(raw)) |it| {
            try drop.both(&out, arena, &para, &quote);
            var marker = it.marker;
            if (marker.len != 0 and (marker[0] < '0' or marker[0] > '9')) {
                marker = switch (@divTrunc(it.indent, 2)) {
                    0 => "•",
                    else => "·",
                };
            }
            try out.append(arena, .{
                .kind = .list,
                .marker = marker,
                .level = @min(@divTrunc(it.indent, 2), 3),
                .text = try plain(arena, it.text),
            });
            continue;
        }

        if (trimmed.len == 0) {
            try drop.both(&out, arena, &para, &quote);
            continue;
        }

        try gather.one(&out, arena, quote.items, .quote);
        quote.clearRetainingCapacity();
        try para.appendSlice(arena, trimmed);
        try para.append(arena, ' ');
    }
    if (fence) |f| {
        if (f.items.len > 0) {
            const crop = f.items[0 .. f.items.len - 1];
            const as_mermaid = fence_mermaid;
            if (as_mermaid) {
                if (matched(arena, images, crop)) |img| {
                    try out.append(arena, .{ .kind = .image, .image = img, .text = "" });
                } else {
                    try out.append(arena, .{ .kind = .code, .text = try arena.dupe(u8, crop) });
                }
            } else {
                try out.append(arena, .{ .kind = .code, .text = try arena.dupe(u8, crop) });
            }
        }
    }
    try drop.both(&out, arena, &para, &quote);
    return out.items;
}

/// The image whose key is the fence's source, with its JPEG decoded.
fn matched(arena: std.mem.Allocator, images: []const Image, crop: []const u8) ?EmbeddedImage {
    const key = std.mem.trim(u8, crop, " \t\r\n");
    for (images, 0..) |img, i| {
        if (!validImageDimensions(img)) continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, img.key, " \t\r\n"), key)) continue;
        var out = EmbeddedImage{ .width = img.width, .height = img.height, .object = 7 + i };
        out.jpeg = decode64(arena, img.jpeg) catch continue;
        out.name = std.fmt.allocPrint(arena, "Im{d}", .{i}) catch continue;
        return out;
    }
    return null;
}

fn validImageDimensions(img: Image) bool {
    return img.width > 0 and img.height > 0 and img.width <= 16384 and img.height <= 16384 and
        @as(u64, img.width) * img.height <= 32 * 1024 * 1024;
}

/// The base64 of `payload` decoded; a data-url prefix comes off first.
pub fn decode64(arena: std.mem.Allocator, payload: []const u8) Error![]u8 {
    const prefix = "data:image/jpeg;base64,";
    const b64 = if (std.mem.startsWith(u8, payload, prefix)) payload[prefix.len..] else payload;
    const Decoder = std.base64.standard.Decoder;
    const n = Decoder.calcSizeForSlice(b64) catch return error.OutOfMemory;
    const bytes = arena.alloc(u8, n) catch return error.OutOfMemory;
    Decoder.decode(bytes, b64) catch return error.OutOfMemory;
    return bytes;
}

fn headingOf(raw: []const u8) ?usize {
    var i: usize = 0;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
    if (i >= raw.len or raw[i] != '#') return null;
    var level: usize = 0;
    while (i < raw.len and raw[i] == '#') : (i += 1) level += 1;
    if (level > 6 or i >= raw.len or (raw[i] != ' ' and raw[i] != '\t')) return null;
    return level;
}

fn isRule(raw: []const u8) bool {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len < 3) return false;
    for (t) |c| switch (c) {
        '-', '_', '*' => {},
        else => return false,
    };
    return true;
}

const ListItem = struct { marker: []const u8, indent: usize, text: []const u8 };

fn listOf(raw: []const u8) ?ListItem {
    var indent: usize = 0;
    while (indent < raw.len and (raw[indent] == ' ' or raw[indent] == '\t')) : (indent += 1) {}
    const rest = raw[indent..];
    if (rest.len < 2) return null;
    const marker_len: usize = switch (rest[0]) {
        '-', '*', '+' => 1,
        '0'...'9' => blk: {
            var k: usize = 0;
            while (k < rest.len and rest[k] >= '0' and rest[k] <= '9') : (k += 1) {}
            if (k >= rest.len or (rest[k] != '.' and rest[k] != ')')) return null;
            break :blk k + 1;
        },
        else => return null,
    };
    if (rest.len <= marker_len or rest[marker_len] != ' ') return null;
    return .{
        .marker = rest[0..marker_len],
        .indent = indent,
        .text = rest[marker_len + 1 ..],
    };
}

/// The line's text without its inline markers: `**bold**`, `*em*` and
/// `` `code` `` stay readable, and `[label](url)` reads "label (url)"
/// unless the label is the url. Marker pairs that never close keep
/// whatever was after them.
fn plain(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const s = std.mem.trim(u8, raw, " \t");
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse s.len;
            try out.appendSlice(arena, s[i + 1 .. close]);
            i = close + 1;
            continue;
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, ']')) |br| {
                if (br + 1 < s.len and s[br + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, br + 2, ')')) |par| {
                        const label = s[i + 1 .. br];
                        const url = s[br + 2 .. par];
                        try out.appendSlice(arena, label);
                        if (!std.ascii.eqlIgnoreCase(label, url)) {
                            try out.appendSlice(arena, " (");
                            try out.appendSlice(arena, url);
                            try out.append(arena, ')');
                        }
                        i = par + 1;
                        continue;
                    }
                }
            }
        }
        if (c == '*' or c == '_') {
            const double = i + 1 < s.len and s[i + 1] == c;
            const open = i + (if (double) @as(usize, 2) else 1);
            const needle = if (double) s[i .. i + 2] else s[i .. i + 1];
            if (std.mem.indexOfPos(u8, s, open, needle)) |at| {
                try out.appendSlice(arena, s[open..at]);
                i = at + (if (double) @as(usize, 2) else 1);
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

// ---- fonts, bytes and widths ------------------------------------------------------------

const Font = enum {
    body, // Helvetica 11/16.5
    bold, // Helvetica-Bold
    quote, // Helvetica-Oblique
    code, // Courier

    /// The resource name the pages reference (/F1..) and, +2, the object
    /// number that defines it (objects 3-6: body, bold, code, quote).
    fn id(self: Font) usize {
        return switch (self) {
            .body => 1,
            .bold => 2,
            .code => 3,
            .quote => 4,
        };
    }

    fn base(self: Font) []const u8 {
        return switch (self) {
            .body => "Helvetica",
            .bold => "Helvetica-Bold",
            .quote => "Helvetica-Oblique",
            .code => "Courier",
        };
    }

    /// The per-glyph width as a fraction of the size. Courier's 0.6 is
    /// exact; the proportional faces get pessimistic class estimates, so
    /// every wrapped line fits even in a run of wide glyphs.
    fn pitch(self: Font, c: u8, size: f32) f32 {
        if (self == .code) return 0.6 * size;
        if (self == .bold) {
            // Bold runs wider: the estimates firm up a little.
            const base_frac = pitch(.body, c, size);
            if (base_frac > 0.6) return base_frac + 0.02;
        }
        const frac: f32 = blk: {
            if (std.mem.indexOfScalar(u8, "ijl!I.,;:'|", c) != null) break :blk 0.30;
            if (std.mem.indexOfScalar(u8, "ftr()[]-/'\\", c) != null) break :blk 0.36;
            if (c == 'm') break :blk 0.83;
            if (c == 'w') break :blk 0.74;
            if (c == 'M') break :blk 0.89;
            if (c == 'W') break :blk 0.94;
            if (c == '@') break :blk 0.92;
            if (c == ' ' or c == '\t') break :blk 0.28;
            if (c >= '0' and c <= '9') break :blk 0.56;
            if (c >= 'A' and c <= 'Z') break :blk 0.72;
            if (c >= 'a' and c <= 'z') break :blk 0.52;
            break :blk 0.55;
        };
        return frac * size;
    }
};

/// The text as one WinAnsiEncoding byte per character (the base-14 fonts'
/// encoding); unfits characters become '?'. The PDF string escapes at emit
/// time.
pub fn winansi(arena: std.mem.Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) return error.OutOfMemory;
        const cp: u21 = std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += 1;
            continue;
        };
        try out.append(arena, winAnsiByte(cp));
        i += len;
    }
    return out.items;
}

fn winAnsiByte(cp: u21) u8 {
    // 0x20-0x7e copy; Latin-1 0xa0-0xff is identical; the WinAnsi set's own
    // spots (€ · ‘ ’ “ ” • – — ˜ ™ š › œ ž Š ‹ Œ Ž).
    const map = [_]struct { u21, u8 }{
        .{ 0x20AC, 0x80 }, .{ 0x2026, 0x85 }, .{ 0x2018, 0x91 }, .{ 0x2019, 0x92 },
        .{ 0x201C, 0x93 }, .{ 0x201D, 0x94 }, .{ 0x2022, 0x95 }, .{ 0x2013, 0x96 },
        .{ 0x2014, 0x97 }, .{ 0x02DC, 0x98 }, .{ 0x2122, 0x99 }, .{ 0x0161, 0x9A },
        .{ 0x203A, 0x9B }, .{ 0x0153, 0x9C }, .{ 0x0160, 0x8A }, .{ 0x2039, 0x8B },
        .{ 0x0152, 0x8C }, .{ 0x017D, 0x8E }, .{ 0x017E, 0x9E },
    };
    if (cp >= 0x20 and cp <= 0x7E) return @intCast(cp);
    if (cp >= 0xA0 and cp <= 0xFF) return @intCast(cp);
    for (map) |m| if (m[0] == cp) return m[1];
    return '?';
}

/// The PDF width of a WinAnsi string in points.
fn width(font: Font, size: f32, bytes: []const u8) f32 {
    var w: f32 = 0;
    for (bytes) |c| w += font.pitch(c, size);
    return w;
}

/// A WinAnsi byte array escaped for a PDF literal string.
pub fn literal(arena: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |c| switch (c) {
        '(', ')', '\\' => {
            try out.append(arena, '\\');
            try out.append(arena, c);
        },
        else => |plain_byte| {
            if (plain_byte >= 0x20 and plain_byte < 0x7f) try out.append(arena, plain_byte) else try out.print(arena, "\\{o:0>3}", .{plain_byte});
        },
    };
    return out.items;
}

fn pt(arena: std.mem.Allocator, value: f32) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d:.2}", .{value}) catch return error.OutOfMemory;
}

// ---- layout ------------------------------------------------------------------------------

/// The pages' content streams: text and rectangle ops, one per page. The
/// page number joins each stream in `finish`, then the file assembles.
const Doc = struct {
    arena: std.mem.Allocator,
    images: []const Image = &.{},
    pages: std.ArrayList(std.ArrayList(u8)) = .empty,
    page_open: bool = false,
    y: f32 = 0,
    image_follows_heading: bool = false,

    fn init(arena: std.mem.Allocator) Doc {
        return .{ .arena = arena };
    }

    fn out(self: *Doc) *std.ArrayList(u8) {
        if (!self.page_open) self.newPage();
        return &self.pages.items[self.pages.items.len - 1];
    }

    fn newPage(self: *Doc) void {
        self.pages.append(self.arena, .empty) catch {};
        self.page_open = true;
        self.y = page_h - margin;
    }

    /// Break the page when `need` more points wouldn't fit.
    fn room(self: *Doc, need: f32) void {
        if (self.pages.items.len == 0) self.newPage();
        if (self.y - need < foot + 4) self.newPage();
    }

    fn gap(self: *Doc, plus: f32) Error!void {
        if (self.pages.items.len == 0) self.newPage();
        self.y -= plus;
    }

    /// One text run at the current baseline.
    fn run(self: *Doc, bytes: []const u8, font: Font, size: f32, x: f32) Error!void {
        const ops = self.out();
        const lit = try literal(self.arena, bytes);
        const xs = try pt(self.arena, x);
        const ys = try pt(self.arena, self.y);
        try ops.print(self.arena, "BT /F{d} {d:.1} Tf {s} {s} Td ({s}) Tj ET\n", .{ font.id(), size, xs, ys, lit });
    }

    /// A gray rectangle.
    fn rect(self: *Doc, x: f32, y: f32, w: f32, h: f32, gray: f32) Error!void {
        const ops = self.out();
        try ops.print(self.arena, "q {d:.2} g {s} {s} {s} {s} re f Q\n", .{ gray, try pt(self.arena, x), try pt(self.arena, y), try pt(self.arena, w), try pt(self.arena, h) });
    }

    /// The heading's face and size by level: 18.5/23, 14.5/19, 12/16.5.
    fn heading(self: *Doc, plain_text: []const u8, level: u8) Error!void {
        const shape: struct { f32, f32 } = switch (level) {
            1 => .{ 18.5, 23 },
            2 => .{ 14.5, 19 },
            else => .{ 12, 16.5 },
        };
        try self.flowing(plain_text, .bold, shape[0], shape[1], 0, "");
    }

    /// Reserve the heading and the following block's first useful portion.
    /// A large diagram can start here and continue on subsequent pages.
    fn keepHeading(self: *Doc, b: Block, next: ?Block) Error!void {
        self.image_follows_heading = if (next) |n| n.kind == .image else false;
        const size: f32 = if (b.level == 1) 18.5 else if (b.level == 2) 14.5 else 12;
        const lead: f32 = if (b.level == 1) 23 else if (b.level == 2) 19 else 16.5;
        const lines = try wrapLines(self.arena, try winansi(self.arena, b.text), .bold, size, text_w - 6);
        const heading_h = @as(f32, @floatFromInt(lines.len)) * lead + 20;
        var following: f32 = 33;
        if (next) |n| {
            if (n.kind == .image) {
                const layout = imageLayout(n.image);
                const full_h = page_h - margin - foot - 40;
                following = if (layout.height + heading_h <= full_h) layout.height + 32 else 240;
            }
        }
        self.room(@min(heading_h + following, page_h - margin - foot - 8));
    }

    /// Wrapped text in one face, indented by `indent`. A non-empty `marker`
    /// ("•" or "5.") hangs before a list's first line.
    fn flowing(self: *Doc, plain_text: []const u8, font: Font, size: f32, lead: f32, indent: f32, marker: []const u8) Error!void {
        const bytes = try winansi(self.arena, plain_text);
        const lines = try wrapLines(self.arena, bytes, font, size, text_w - indent - 6);
        self.room(lead);
        var first = true;
        for (lines) |line| {
            if (!first) {
                self.y -= lead;
                self.room(lead);
            }
            if (first and marker.len > 0) {
                const mk = try winansi(self.arena, marker);
                const mw = width(font, size, mk);
                try self.run(mk, font, size, margin + indent - mw - 4);
            }
            try self.run(line, font, size, margin + indent);
            first = false;
        }
        self.y -= lead;
    }

    /// A quote: the lines in italic beside a slim left rule; a page break
    /// under a quote starts a fresh rule on the new page.
    fn quote(self: *Doc, plain_text: []const u8) Error!void {
        const size: f32 = 10.5;
        const lead: f32 = 15;
        const bytes = try winansi(self.arena, plain_text);
        const lines = try wrapLines(self.arena, bytes, .quote, size, text_w - 20);
        self.room(lead);
        var seg_first: f32 = 0;
        var open = false;
        for (lines) |line| {
            if (open and self.y - lead < foot) {
                try self.fillRect(margin, self.y + lead - 3.5, 2.4, seg_first + 3.5 - (self.y + lead - 3.5), 0.82);
                open = false;
            }
            if (!open) {
                self.room(lead);
                seg_first = self.y;
                open = true;
            }
            try self.run(line, .quote, size, margin + 12);
            self.y -= lead;
        }
        if (open) {
            const below = self.y + lead - 3.5;
            try self.fillRect(margin, below, 2.4, seg_first + 3.5 - below, 0.82);
        }
        self.y -= 14;
    }

    fn fillRect(self: *Doc, x: f32, y: f32, w: f32, h: f32, gray: f32) Error!void {
        return self.rect(x, y, w, h, gray);
    }

    /// A horizontal rule.
    fn rule(self: *Doc) Error!void {
        self.room(10);
        try self.rect(margin, self.y - 3, text_w, 0.8, 0.8);
        self.y -= 9;
    }

    const ImageLayout = struct { width: f32, height: f32 };

    fn imageLayout(img: EmbeddedImage) ImageLayout {
        std.debug.assert(img.width > 0 and img.height > 0);
        // Two samples per CSS pixel. Keep at least 80% of the natural
        // size; beyond that, paginate rather than shrinking every label.
        const w: f32 = @floatFromInt(img.width);
        const scale = @max(@as(f32, 0.30), @min(@as(f32, 0.375), text_w / w));
        return .{ .width = w * scale, .height = @as(f32, @floatFromInt(img.height)) * scale };
    }

    /// Diagrams too large for the column span overlapping panels. PDF
    /// clipping reuses the original JPEG without making cropped copies.
    fn imageBlock(self: *Doc, b: Block) Error!void {
        const img = b.image;
        const layout = imageLayout(img);
        const bottom = foot + 18;
        const full_h = page_h - margin - bottom;
        const tiled = layout.width > text_w + 0.01 or layout.height > full_h or
            (self.image_follows_heading and layout.height > self.y - bottom - 4);
        self.image_follows_heading = false;
        if (!tiled) {
            self.room(layout.height + 20);
            try self.imageTile(img, layout, 0, 0, layout.width, layout.height);
            return;
        }
        const overlap_x: f32 = 96;
        const overlap_y: f32 = 48;
        const columns: usize = @intFromFloat(@max(1, @ceil((layout.width - overlap_x) / (text_w - overlap_x))));
        const tile_w = (layout.width + @as(f32, @floatFromInt(columns - 1)) * overlap_x) / @as(f32, @floatFromInt(columns));
        var top: f32 = 0;
        var row: usize = 0;
        // Accepted images are bounded to 16K samples per side, so 256
        // panels comfortably bounds both dimensions at the minimum scale.
        while (top < layout.height and row < 256) : (row += 1) {
            self.room(@min(layout.height - top, 180) + 36);
            const remaining = layout.height - top;
            const available = self.y - bottom - 22;
            const rows: f32 = @max(1, @ceil((remaining - overlap_y) / (available - overlap_y)));
            const tile_h = @min(available, (remaining + (rows - 1) * overlap_y) / rows);
            for (0..columns) |column| {
                if (column > 0) {
                    try self.gap(14);
                    self.room(tile_h + 42);
                }
                const label = try std.fmt.allocPrint(self.arena, "Diagram detail - row {d}, column {d} of {d}", .{ row + 1, column + 1, columns });
                try self.run(label, .quote, 9, margin);
                self.y -= 22;
                try self.imageTile(img, layout, @as(f32, @floatFromInt(column)) * (tile_w - overlap_x), top, tile_w, tile_h);
            }
            if (tile_h >= remaining - 0.01) break;
            top += tile_h - overlap_y;
            self.newPage();
        }
    }

    fn imageTile(self: *Doc, img: EmbeddedImage, layout: ImageLayout, left: f32, top: f32, w: f32, h: f32) Error!void {
        std.debug.assert(w > 0 and h > 0);
        std.debug.assert(w <= text_w + 0.01);
        const x = margin + (text_w - w) / 2;
        const y = self.y - h;
        try self.out().print(self.arena, "q {s} {s} {s} {s} re W n {s} 0 0 {s} {s} {s} cm /{s} Do Q\n", .{
            try pt(self.arena, x),            try pt(self.arena, y),             try pt(self.arena, w),        try pt(self.arena, h),
            try pt(self.arena, layout.width), try pt(self.arena, layout.height), try pt(self.arena, x - left), try pt(self.arena, self.y + top - layout.height),
            img.name,
        });
        self.y = y - 2;
    }

    fn codeBlock(self: *Doc, text: []const u8) Error!void {
        const size: f32 = 9;
        const lead: f32 = 12.6;
        const lines = try wrapLines(self.arena, text, .code, size, text_w - 24);
        if (lines.len == 0) return;
        var left: usize = lines.len;
        while (left > 0) {
            self.room(lead);
            const fit = @floor((self.y - foot - 8) / lead);
            const take: usize = @intFromFloat(@min(fit, @as(f32, @floatFromInt(left))));
            if (take == 0) {
                self.newPage();
                continue;
            }
            const slice = lines[lines.len - left ..][0..take];
            const first = self.y;
            const last = first - lead * @as(f32, @floatFromInt(take - 1));
            try self.rect(margin + 6, last - 4, text_w - 8, first + 4 - (last - 4), 0.94);
            for (slice) |line| {
                try self.run(line, .code, size, margin + 12);
                self.y -= lead;
            }
            left -= take;
            if (left > 0) self.newPage();
        }
    }

    /// The first page's header: the title, a small line under it, a rule.
    fn titlePage(self: *Doc, title: []const u8, subtitle: []const u8) Error!void {
        try self.flowing(if (title.len == 0) "Summary" else title, .bold, 21, 26, 0, "");
        if (subtitle.len > 0) {
            self.y -= 4;
            try self.run(try winansi(self.arena, subtitle), .quote, 9.5, margin);
            self.y -= 15;
        }
        try self.rect(margin, self.y - 4, text_w, 1, 0.75);
        self.y -= 12;
    }

    /// The whole file. Each page's stream grows its page number, then the
    /// objects, xref and trailer assemble in order of object number.
    fn finish(self: *Doc) Error![]const u8 {
        const count = self.pages.items.len;
        const k = self.images.len;
        const objects = 6 + k + 2 * count; // catalog, pages, 4 fonts, images, then page+stream each
        var body: std.ArrayList(u8) = .empty;
        var offsets = try self.arena.alloc(usize, objects + 1);
        @memset(offsets, 0);

        const w = &body;
        try w.appendSlice(self.arena, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");

        const mark = struct {
            fn at(offs: []usize, bytes: *std.ArrayList(u8), a: std.mem.Allocator, object: usize) Error!void {
                offs[object - 1] = bytes.items.len;
                try bytes.print(a, "{d} 0 obj\n", .{object});
            }
        };

        // 1: catalog, 2: page tree.
        try mark.at(offsets, w, self.arena, 1);
        try w.appendSlice(self.arena, "<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        try mark.at(offsets, w, self.arena, 2);
        try w.appendSlice(self.arena, "<< /Type /Pages /Kids [");
        for (0..count) |i| try w.print(self.arena, " {d} 0 R", .{7 + k + 2 * i});
        try w.print(self.arena, " ] /Count {d} >>\nendobj\n", .{count});

        // 3-6: the four fonts (in /Font resource order).
        for (0..4) |fi| {
            const object = 3 + fi;
            const role: Font = switch (fi) {
                0 => .body,
                1 => .bold,
                2 => .code,
                else => .quote,
            };
            try mark.at(offsets, w, self.arena, object);
            try w.print(self.arena, "<< /Type /Font /Subtype /Type1 /BaseFont /{s} /Encoding /WinAnsiEncoding >>\nendobj\n", .{role.base()});
        }

        // 7..7+k-1: the diagrams' JPEG XObjects.
        for (self.images, 0..) |image, i| {
            const object = 7 + i;
            try mark.at(offsets, w, self.arena, object);
            const jpeg = decode64(self.arena, image.jpeg) catch &.{};
            try w.print(self.arena, "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ image.width, image.height, jpeg.len, jpeg });
        }

        // 7+k+: each page and its content stream.
        for (self.pages.items, 0..) |page, i| {
            const page_obj: usize = 7 + k + 2 * i;
            const stream_obj = page_obj + 1;
            const footer = try std.fmt.allocPrint(self.arena, "BT /F1 9 Tf {s} {s} Td ({d}) Tj ET\n", .{
                try pt(self.arena, (page_w - width(.body, 9, "0")) / 2),
                try pt(self.arena, foot),
                i + 1,
            });
            const stream = try std.mem.concat(self.arena, u8, &.{ page.items, footer });
            try mark.at(offsets, w, self.arena, page_obj);
            try w.print(self.arena, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Contents {d} 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R >>", .{stream_obj});
            if (k > 0) {
                try w.appendSlice(self.arena, " /XObject <<");
                for (self.images, 0..) |_, n| try w.print(self.arena, " /Im{d} {d} 0 R", .{ n, 7 + n });
                try w.appendSlice(self.arena, " >>");
            }
            try w.appendSlice(self.arena, " >> >>\nendobj\n");
            try mark.at(offsets, w, self.arena, stream_obj);
            try w.print(self.arena, "<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ stream.len, stream });
        }

        const startxref = w.items.len;
        try w.print(self.arena, "xref\n0 {d}\n0000000000 65535 f \n", .{objects + 1});
        for (offsets[0..objects]) |o| try w.print(self.arena, "{d:0>10} 00000 n \n", .{o});
        try w.print(self.arena, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ objects + 1, startxref });
        return body.items;
    }
};

/// The text broken to fit `max_w`: on spaces, hard-wrapping a word wider
/// than the whole line. Empty text makes an empty list (checks skip it).
pub fn wrapLines(arena: std.mem.Allocator, bytes: []const u8, font: Font, size: f32, max_w: f32) Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var cur_w: f32 = 0;

    const flush = struct {
        fn line(l: *std.ArrayList([]const u8), a: std.mem.Allocator, s: *std.ArrayList(u8)) Error!void {
            if (s.items.len == 0) return;
            try l.append(a, try a.dupe(u8, s.items));
            s.clearRetainingCapacity();
        }
    };

    var it = std.mem.tokenizeAny(u8, bytes, " \t\n");
    while (it.next()) |word| {
        const w = width(font, size, word);
        // A word wider than the whole line chunks by glyph.
        if (w > max_w) {
            if (cur.items.len > 0) {
                try flush.line(&lines, arena, &cur);
                cur_w = 0;
            }
            var start: usize = 0;
            var fit: f32 = 0;
            for (word, 0..) |c, k| {
                const cw = font.pitch(c, size);
                if (fit + cw > max_w and k > start) {
                    try lines.append(arena, word[start..k]);
                    start = k;
                    fit = cw;
                } else fit += cw;
            }
            try cur.appendSlice(arena, word[start..]);
            cur_w = fit;
            continue;
        }
        if (cur.items.len > 0 and cur_w + w > max_w) {
            try flush.line(&lines, arena, &cur);
            cur_w = 0;
        } else if (cur.items.len > 0) {
            try cur.append(arena, ' ');
            cur_w += font.pitch(' ', size);
        }
        cur_w += w;
        try cur.appendSlice(arena, word);
    }
    try flush.line(&lines, arena, &cur);
    return lines.items;
}

// ---- tests -------------------------------------------------------------------------------

test "a markdown summary renders as a valid PDF" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try render(a, .{
        .title = "Device secret rotation",
        .subtitle = "GhostPen summary · 2026-10-20",
        .markdown =
        \\# Key points
        \\
        \\- The design introduces a random **128-bit** `cid` claim to every device token.
        \\- Rotation is triggered by an owner request, followed by a device-only exchange.
        \\
        \\## Details
        \\
        \\> A token without `cid` is treated as minted under whatever secret the device had.
        \\
        \\Some discretion is required here: the Hub stores the current secret and a pending
        \\one during rotation, accepting tokens from either as long as the pending one has
        \\not expired yet — including the MQTT kind (see [the doc](https://example.com)).
        \\
        \\```mermaid
        \\sequenceDiagram
        \\    O->>H: POST rotation
        \\```
        \\
        \\---
        \\
        \\Done.
        ,
    });
    try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "%%EOF\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(Device secret rotation)") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "128-bit cid claim") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sequenceDiagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Count 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "startxref") != null);
}

test "the markdown subset: headings, lists, quotes, fences, inline marks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bs = try blocksForTesting(
        a,
        \\# Also the top
        \\
        \\#### A deep heading flattens
        \\
        \\Text with **bold**, *em*, `code`, [site](https://example.com) and [url](url).
        \\
        \\* one bullet
        \\*two not a bullet
        \\  5. numbered
        \\
        \\> a quote
        \\> two lines here
        \\
        \\---
        ,
    );
    try std.testing.expectEqual(@as(usize, 8), bs.len);
    try std.testing.expectEqual(Block.Kind.heading, bs[0].kind);
    try std.testing.expectEqual(@as(u8, 1), bs[0].level);
    try std.testing.expectEqualStrings("Also the top", bs[0].text);
    try std.testing.expectEqual(@as(u8, 3), bs[1].level);
    try std.testing.expectEqualStrings("Text with bold, em, code, site (https://example.com) and url.", bs[2].text);
    try std.testing.expectEqual(Block.Kind.list, bs[3].kind);
    try std.testing.expectEqualStrings("•", bs[3].marker);
    try std.testing.expectEqual(Block.Kind.para, bs[4].kind);
    try std.testing.expectEqualStrings("*two not a bullet", bs[4].text);
    try std.testing.expectEqualStrings("5.", bs[5].marker);
    try std.testing.expectEqual(@as(u8, 1), bs[5].level);
    try std.testing.expectEqualStrings("a quote two lines here", bs[6].text);
    try std.testing.expectEqual(Block.Kind.rule, bs[7].kind);
}

test "a rendered diagram embeds as a JPEG, the whole one on its page" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var b64: [64]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&b64, "PRETEND-JPEG-BYTES");
    const source = "sequenceDiagram\n    O->>H: POST rotation";
    const bytes = try render(a, .{
        .title = "With a diagram",
        .markdown = "Before.\n\n```mermaid\n" ++ "sequenceDiagram\n    O->>H: POST rotation\n```\n\nAfter.",
        .images = &.{.{ .key = source, .jpeg = try a.dupe(u8, b64[0..payload.len]), .width = 210, .height = 88 }},
    });
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/DCTDecode") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Width 210") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Im0 Do") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "(sequenceDiagram") == null); // the source went when the image came
    try std.testing.expect(std.mem.indexOf(u8, bytes, "PRETEND-JPEG-BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Count 1") != null);
    // A fence without a matching image keeps its code block (key mismatch).
    const only_source = try render(a, .{
        .title = "No image",
        .markdown = "```mermaid\nsequenceDiagram\n    A->>B: hello\n```\n",
    });
    try std.testing.expect(std.mem.indexOf(u8, only_source, "/Subtype /Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, only_source, "(sequenceDiagram") != null);
}

test "WinAnsi and inline bytes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const b = try winansi(a, "• dash — “quoted” \u{2713}");
    try std.testing.expectEqual(@as(u8, 0x95), b[0]);
    try std.testing.expectEqual(@as(u8, 0x97), b[7]);
    try std.testing.expectEqual(@as(u8, 0x93), b[9]);
    try std.testing.expectEqual(@as(u8, 0x94), b[16]);
    try std.testing.expectEqual(@as(u8, '?'), b[18]);
    const lit = try literal(a, "a(b\\c");
    try std.testing.expectEqualStrings("a\\(b\\\\c", lit);
    try std.testing.expectEqual(@as(f32, 5.94), @round(width(.code, 3.3, "aaa") * 100) / 100);
}

test "oversized diagrams keep readable scale and span clipped overlapping panels" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tall = Doc.init(a);
    try tall.titlePage("Tall diagram", "");
    const tall_image = EmbeddedImage{ .width = 264, .height = 5616 };
    const layout = Doc.imageLayout(tall_image);
    try std.testing.expectEqual(@as(f32, 2106), layout.height);
    try tall.heading("Flow", 2);
    try tall.imageBlock(.{ .kind = .image, .text = "", .image = tall_image });
    try std.testing.expect(tall.pages.items.len >= 3);
    for (tall.pages.items) |page| {
        try std.testing.expect(std.mem.indexOf(u8, page.items, "/Im0 Do") != null);
        try std.testing.expect(std.mem.indexOf(u8, page.items, "re W n") != null);
        try std.testing.expect(std.mem.indexOf(u8, page.items, "2106.00") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, tall.pages.items[0].items, "(Flow)") != null);
    var wide = Doc.init(a);
    wide.newPage();
    try wide.imageBlock(.{ .kind = .image, .text = "", .image = .{ .width = 4920, .height = 128 } });
    try std.testing.expectEqual(@as(usize, 1), wide.pages.items.len);
    for (wide.pages.items) |page| {
        try std.testing.expect(std.mem.indexOf(u8, page.items, "1476.00") != null);
        try std.testing.expect(std.mem.indexOf(u8, page.items, "Diagram detail - row 1, column") != null);
        try std.testing.expect(std.mem.indexOf(u8, page.items, "column 4 of 4") != null);
    }
}

test "heading moves with a normal diagram when the pair would cross a page" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var doc = Doc.init(a);
    try doc.titlePage("Summary", "");
    doc.y = foot + 100;
    const heading = Block{ .kind = .heading, .level = 2, .text = "Sequence" };
    const diagram = Block{ .kind = .image, .text = "", .image = .{ .width = 1462, .height = 834 } };
    try doc.keepHeading(heading, diagram);
    try doc.gap(15);
    try doc.heading(heading.text, heading.level);
    try doc.gap(13);
    try doc.imageBlock(diagram);
    try std.testing.expectEqual(@as(usize, 2), doc.pages.items.len);
    const second = doc.pages.items[1].items;
    try std.testing.expect(std.mem.indexOf(u8, second, "(Sequence)") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "/Im0 Do") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.pages.items[0].items, "(Sequence)") == null);
}

test "tilde and CRLF Mermaid fences match images and invalid dimensions keep code" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const markdown = "~~~ MERMAID\r\nflowchart LR\r\n A-->B\r\n~~~\r\n";
    const image = Image{ .key = "flowchart LR\n A-->B", .jpeg = "SlBFRw==", .width = 200, .height = 160 };
    const content = try blocks(a, markdown, &.{image});
    try std.testing.expectEqual(Block.Kind.image, content[0].kind);
    var invalid = image;
    invalid.width = 0;
    const fallback = try blocks(a, markdown, &.{invalid});
    try std.testing.expectEqual(Block.Kind.code, fallback[0].kind);
    const bytes = try render(a, .{ .title = "Fallback", .markdown = markdown, .images = &.{invalid} });
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Image") == null);
}

test "a nearly page-high diagram starts under its heading instead of orphaning it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var doc = Doc.init(arena_state.allocator());
    try doc.titlePage("Summary", "");
    const heading = Block{ .kind = .heading, .level = 2, .text = "Tall sequence" };
    const diagram = Block{ .kind = .image, .text = "", .image = .{ .width = 600, .height = 1900 } };
    try doc.keepHeading(heading, diagram);
    try doc.gap(15);
    try doc.heading(heading.text, heading.level);
    try doc.gap(13);
    try doc.imageBlock(diagram);
    try std.testing.expectEqual(@as(usize, 2), doc.pages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, doc.pages.items[0].items, "(Tall sequence)") != null);
    for (doc.pages.items) |page| {
        try std.testing.expect(std.mem.indexOf(u8, page.items, "/Im0 Do") != null);
    }
}
