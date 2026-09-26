//! OpenAI-compatible `/chat/completions` client: one code path for Ollama,
//! LM Studio, OpenAI, OpenRouter, Groq and any compatible endpoint.
//!
//! Ported from GhostPen's ai.rs: the same prompts (verbatim), the same
//! two-pass "thinking off, retry with thinking on if the model leaked its
//! reasoning" strategy, SSE streaming, vision input for OCR, `GET /models`,
//! and bounded requests with readable errors.

const std = @import("std");
const settings = @import("settings.zig");
const local_llm = @import("local_llm.zig");

pub const Profile = settings.Profile;

/// Resolves a "Built-in" profile to the runner's configuration (model
/// file, context, GPU); set by the app and the CLI. Null: no built-in models.
pub var local_resolver: ?*const fn (arena: std.mem.Allocator, profile: Profile, diag: *Diag) Error!local_llm.Config = null;

/// Total time for one request (the Tauri app's reqwest timeout).
pub const request_timeout_ms: u32 = 60_000;
pub const max_tokens = 2048;

pub const Level = enum { subtle, balanced, strong };

/// Why a request failed, for the UI. Points into the arena passed to the call.
pub const Diag = struct { message: []const u8 = "" };

pub const Error = error{ AiFailed, OutOfMemory };

// ---- prompts ---------------------------------------------------------------------------

/// The system prompt of a built-in action, or null for an unknown id.
pub fn builtinPrompt(arena: std.mem.Allocator, action: []const u8, lang: ?[]const u8, level: Level) !?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, action, "proofread"))
        return "Fix all spelling, grammar, syntax, and punctuation errors. Maintain the original tone. Return ONLY the finalized text. No conversational filler, notes, or wrapper quotes.";
    if (eq(u8, action, "professional")) return switch (level) {
        .subtle => "Lightly adjust the text to sound a bit more professional and polished, staying close to the original wording and length. Return ONLY the rewritten text, with no explanations.",
        .strong => "Rewrite the text into a highly formal, polished, corporate-professional tone. Return ONLY the rewritten text, with no explanations.",
        .balanced => "Rewrite the text to be professional, polite, and clear. Return ONLY the rewritten text, with no explanations.",
    };
    if (eq(u8, action, "casual")) return switch (level) {
        .subtle => "Lightly relax the tone to be a bit more casual and friendly, keeping it close to the original. Return ONLY the rewritten text, with no explanations.",
        .strong => "Rewrite the text in a very casual, relaxed, informal tone \u{2014} like chatting with a close friend. Return ONLY the rewritten text, with no explanations.",
        .balanced => "Rewrite the text in a casual, friendly, conversational tone. Keep it natural and approachable. Return ONLY the rewritten text, with no explanations.",
    };
    if (eq(u8, action, "concise")) return switch (level) {
        .subtle => "Tighten the text slightly, trimming obvious redundancy while keeping nearly all detail. Return ONLY the condensed text.",
        .strong => "Aggressively condense the text to the absolute minimum needed to convey the essential point. Return ONLY the condensed text.",
        .balanced => "Condense the text to be short and precise while preserving all core information. Return ONLY the condensed text.",
    };
    if (eq(u8, action, "expand")) return switch (level) {
        .subtle => "Expand the text slightly with a little more detail and clarity, keeping it close to the original length. Return ONLY the expanded text, with no explanations or filler.",
        .strong => "Substantially expand the text with rich detail, examples, and elaboration, significantly increasing its length while preserving meaning and tone. Return ONLY the expanded text, with no explanations or filler.",
        .balanced => "Expand the text with more detail, elaboration, and supporting context while preserving its original meaning and tone. Return ONLY the expanded text, with no explanations or filler.",
    };
    if (eq(u8, action, "translate"))
        return try std.fmt.allocPrint(arena, "Auto-detect the source language. Translate the text into natural, fluent {s}, preserving formatting and tone. Return ONLY the translated text \u{2014} no filler, explanations, or quotes.", .{lang orelse "English"});
    return null;
}

/// The prompt-bar instruction wrapped as a system prompt (`"` becomes `'`).
pub fn instructionPrompt(arena: std.mem.Allocator, instruction: []const u8) ![]const u8 {
    const safe = try arena.dupe(u8, instruction);
    std.mem.replaceScalar(u8, safe, '"', '\'');
    return std.fmt.allocPrint(arena, "You are a precise text editor. Apply the following instruction to the user's text: \"{s}\". Return ONLY the resulting text \u{2014} no explanations, notes, preamble, or wrapper quotes.", .{safe});
}

pub const ocr_system_prompt = "Extract all visible text from the image. Preserve line breaks and paragraph structure as closely as possible. Return ONLY the extracted text, with no markdown, no explanations, and no wrapper quotes.";
pub const ocr_user_text = "Extract all text from this image.";

// ---- requests --------------------------------------------------------------------------

/// The user message: plain text, or text plus a PNG image (vision models).
pub const UserContent = union(enum) {
    text: []const u8,
    image_with_text: struct { text: []const u8, png: []const u8 },
};

pub const Request = struct {
    profile: Profile,
    system: []const u8,
    user: UserContent,
};

/// The request body (`thinking` toggles the backend's reasoning phase, both
/// spellings: llama.cpp/vLLM `chat_template_kwargs.enable_thinking`, Ollama `think`).
fn buildBody(arena: std.mem.Allocator, req: Request, thinking: bool, stream: bool) error{OutOfMemory}![]const u8 {
    // An Allocating writer only fails when allocation does.
    return writeBody(arena, req, thinking, stream) catch error.OutOfMemory;
}

fn writeBody(arena: std.mem.Allocator, req: Request, thinking: bool, stream: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(req.profile.model);
    try jw.objectField("messages");
    try jw.beginArray();
    try jw.write(.{ .role = "system", .content = req.system });
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    switch (req.user) {
        .text => |t| try jw.write(t),
        .image_with_text => |iw| {
            const b64 = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(iw.png.len));
            _ = std.base64.standard.Encoder.encode(b64, iw.png);
            const url = try std.fmt.allocPrint(arena, "data:image/png;base64,{s}", .{b64});
            try jw.write(.{
                .{ .type = "text", .text = iw.text },
                .{ .type = "image_url", .image_url = .{ .url = url } },
            });
        },
    }
    try jw.endObject();
    try jw.endArray();
    try jw.objectField("temperature");
    try jw.write(req.profile.temperature);
    try jw.objectField("max_tokens");
    try jw.write(max_tokens);
    try jw.objectField("chat_template_kwargs");
    try jw.write(.{ .enable_thinking = thinking });
    try jw.objectField("think");
    try jw.write(thinking);
    try jw.objectField("stream");
    try jw.write(stream);
    try jw.endObject();
    return out.written();
}

fn endpoint(arena: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), path });
}

/// One HTTP exchange, bounded by `request_timeout_ms`. The response body is
/// written to `sink`; the status is returned. Network failures set `diag`.
fn exchange(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    api_key: []const u8,
    body: ?[]const u8,
    sink: *std.Io.Writer,
    diag: *Diag,
) Error!std.http.Status {
    const auth: ?[]const u8 = if (api_key.len > 0) try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}) else null;

    const Fetch = struct {
        fn run(i: std.Io, alloc: std.mem.Allocator, m: std.http.Method, u: []const u8, a: ?[]const u8, b: ?[]const u8, w: *std.Io.Writer) anyerror!std.http.Status {
            var client: std.http.Client = .{ .allocator = alloc, .io = i };
            defer client.deinit();
            const res = try client.fetch(.{
                .location = .{ .url = u },
                .method = m,
                .payload = b,
                .keep_alive = false,
                .headers = .{
                    .accept_encoding = .{ .override = "identity" },
                    .content_type = if (b != null) .{ .override = "application/json" } else .default,
                    .authorization = if (a) |v| .{ .override = v } else .default,
                },
                .response_writer = w,
            });
            return res.status;
        }
        fn sleep(i: std.Io, ms: u32) void {
            i.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };
    const Outcome = union(enum) { done: anyerror!std.http.Status, timeout: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, Fetch.run, .{ io, gpa, method, url, auth, body, sink }) catch return fail(diag, "Could not start the request.");
    // The fetch points into this frame: never return while it may still run.
    sel.concurrent(.timeout, Fetch.sleep, .{ io, request_timeout_ms }) catch {
        sel.cancelDiscard();
        return fail(diag, "Could not start the request.");
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        return fail(diag, "Request cancelled.");
    };
    sel.cancelDiscard();
    return switch (first) {
        .timeout => fail(diag, "Request timed out \u{2014} is the endpoint reachable?"),
        .done => |r| r catch |err| switch (err) {
            error.ConnectionRefused, error.UnknownHostName, error.NetworkUnreachable, error.HostUnreachable, error.ConnectionResetByPeer, error.ConnectionTimedOut => fail(diag, "Could not connect to the endpoint."),
            error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat, error.UnexpectedCharacter, error.InvalidPort => fail(diag, "The endpoint URL is not valid."),
            error.OutOfMemory => error.OutOfMemory,
            else => failFmt(arena, diag, "Request failed ({s}).", .{@errorName(err)}),
        },
    };
}

fn fail(diag: *Diag, message: []const u8) error{AiFailed} {
    diag.message = message;
    return error.AiFailed;
}

fn failFmt(arena: std.mem.Allocator, diag: *Diag, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.AiFailed;
}

/// "API 404 Not Found: <first 200 chars of the body>".
fn apiError(arena: std.mem.Allocator, diag: *Diag, status: std.http.Status, body: []const u8) Error {
    const text = truncate(std.mem.trim(u8, body, " \t\r\n"), 200);
    const phrase = status.phrase() orelse "";
    if (text.len == 0) return failFmt(arena, diag, "API returned {d} {s}", .{ @intFromEnum(status), phrase });
    return failFmt(arena, diag, "API {d} {s}: {s}{s}", .{ @intFromEnum(status), phrase, text, if (text.len < std.mem.trim(u8, body, " \t\r\n").len) "\u{2026}" else "" });
}

/// The first `max` bytes of `s`, cut back to a UTF-8 boundary.
fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// One non-streamed completion; the reasoning blocks are stripped.
fn postCompletion(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, thinking: bool, diag: *Diag) Error![]const u8 {
    const body = try buildBody(arena, req, thinking, false);
    var out: std.Io.Writer.Allocating = .init(arena);
    const status = try exchange(io, gpa, arena, .POST, try endpoint(arena, req.profile.baseUrl, "/chat/completions"), req.profile.apiKey, body, &out.writer, diag);
    if (status.class() != .success) return apiError(arena, diag, status, out.written());
    const Resp = struct { choices: []const struct { message: struct { content: ?[]const u8 = null } } };
    const parsed = std.json.parseFromSliceLeaky(Resp, arena, out.written(), .{ .ignore_unknown_fields = true }) catch
        return failFmt(arena, diag, "Parse error: unexpected response from the endpoint", .{});
    const content = if (parsed.choices.len > 0) parsed.choices[0].message.content orelse "" else "";
    return stripReasoning(arena, content);
}

/// One completion on GhostPen's built-in model; `on_chunk` gets the visible deltas.
fn localCompletion(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, thinking: bool, ctx: anytype, comptime on_chunk: fn (@TypeOf(ctx), []const u8) void, diag: *Diag) Error![]const u8 {
    const text = switch (req.user) {
        .text => |t| t,
        .image_with_text => return fail(diag, "The built-in model reads text only: extracting text from images needs a vision model endpoint (choose an endpoint profile)."),
    };
    const resolver = local_resolver orelse return fail(diag, "Built-in models aren't available in this build.");
    const cfg = try resolver(arena, req.profile, diag);
    var message: []const u8 = "";
    const res = local_llm.chat(io, gpa, arena, cfg, .{
        .system = req.system,
        .user = text,
        .temperature = req.profile.temperature,
        .think = thinking,
        .max_tokens = max_tokens,
    }, ctx, on_chunk, &message) catch |err| switch (err) {
        error.LocalFailed => return fail(diag, message),
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (res.cancelled) return fail(diag, "Cancelled.");
    return stripReasoning(arena, res.text);
}

fn ignoreChunk(_: void, _: []const u8) void {}

/// A non-streamed completion from the profile's endpoint or the built-in model.
fn completion(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, thinking: bool, diag: *Diag) Error![]const u8 {
    if (req.profile.isLocal()) return localCompletion(io, gpa, arena, req, thinking, {}, ignoreChunk, diag);
    return postCompletion(io, gpa, arena, req, thinking, diag);
}

/// Thinking off first (fast); retried with thinking on only when the answer
/// came back empty or is visibly the model's reasoning.
pub fn complete(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, diag: *Diag) Error![]const u8 {
    const input: ?[]const u8 = switch (req.user) {
        .text => |t| t,
        .image_with_text => null,
    };
    const first = try completion(io, gpa, arena, req, false, diag);
    if (first.len > 0 and !looksLikeReasoning(first, input)) return first;
    std.log.warn("model leaked reasoning instead of the answer; retrying with thinking enabled", .{});
    const retry = try completion(io, gpa, arena, req, true, diag);
    if (retry.len > 0) return retry;
    if (first.len == 0) return fail(diag, "Model returned empty output");
    return first;
}

/// Streaming completion (SSE): `on_chunk(ctx, delta)` for each content delta.
/// Returns the final text (which may differ from the chunks: a leaked-
/// reasoning answer is replaced by a non-streamed retry).
pub fn completeStream(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    req: Request,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
    diag: *Diag,
) Error![]const u8 {
    if (req.profile.isLocal()) {
        const input = switch (req.user) {
            .text => |t| t,
            .image_with_text => |iw| iw.text,
        };
        const out = try localCompletion(io, gpa, arena, req, false, ctx, on_chunk, diag);
        if (out.len > 0 and !looksLikeReasoning(out, input)) return out;
        std.log.warn("model leaked reasoning into the stream; retrying with thinking enabled", .{});
        const retry = try completion(io, gpa, arena, req, true, diag);
        if (retry.len > 0) return retry;
        if (out.len == 0) return fail(diag, "Model returned empty output");
        return out;
    }
    const body = try buildBody(arena, req, false, true);
    var sink: SseSink(@TypeOf(ctx), on_chunk) = .{ .arena = arena, .ctx = ctx };
    sink.init();
    const status = try exchange(io, gpa, arena, .POST, try endpoint(arena, req.profile.baseUrl, "/chat/completions"), req.profile.apiKey, body, &sink.writer, diag);
    sink.finish() catch {};
    if (sink.oom) return error.OutOfMemory;
    if (status.class() != .success) return apiError(arena, diag, status, sink.raw.items);

    const input = switch (req.user) {
        .text => |t| t,
        .image_with_text => |iw| iw.text,
    };
    const out = try stripReasoning(arena, sink.full.items);
    if (out.len > 0 and !looksLikeReasoning(out, input)) return out;
    std.log.warn("model leaked reasoning into the stream; retrying with thinking enabled", .{});
    const retry = try completion(io, gpa, arena, req, true, diag);
    if (retry.len > 0) return retry;
    if (out.len == 0) return fail(diag, "Model returned empty output");
    return out;
}

/// A writer that parses `data:` lines of an SSE body as they arrive.
fn SseSink(comptime Ctx: type, comptime on_chunk: fn (Ctx, []const u8) void) type {
    return struct {
        const Self = @This();
        arena: std.mem.Allocator,
        ctx: Ctx,
        line: std.ArrayList(u8) = .empty,
        full: std.ArrayList(u8) = .empty,
        /// The start of the body, for error messages.
        raw: std.ArrayList(u8) = .empty,
        done: bool = false,
        oom: bool = false,
        /// One byte: a reader streaming into the writer needs some buffer
        /// (an empty one fails an assertion), and a larger one would hold
        /// the deltas back until it fills. With one byte, each byte reaches
        /// `drain` as soon as the next one arrives; the last byte of an SSE
        /// event is its blank separator line, so no delta waits.
        buf: [1]u8 = undefined,
        writer: std.Io.Writer = undefined,

        fn init(self: *Self) void {
            self.writer = .{ .buffer = &self.buf, .vtable = &.{ .drain = drain, .flush = flush } };
        }

        fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            self.feed(w.buffered()) catch return error.WriteFailed;
            w.end = 0;
        }

        /// Buffered bytes first, then `data` (the Writer contract).
        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            self.feed(w.buffered()) catch return error.WriteFailed;
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |d| {
                self.feed(d) catch return error.WriteFailed;
                n += d.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| {
                self.feed(last) catch return error.WriteFailed;
                n += last.len;
            }
            return n;
        }

        fn feed(self: *Self, bytes: []const u8) !void {
            errdefer self.oom = true;
            if (self.raw.items.len < 1024) try self.raw.appendSlice(self.arena, bytes[0..@min(bytes.len, 1024 - self.raw.items.len)]);
            for (bytes) |b| {
                if (b != '\n') {
                    try self.line.append(self.arena, b);
                    continue;
                }
                try self.handleLine(std.mem.trim(u8, self.line.items, " \t\r"));
                self.line.clearRetainingCapacity();
            }
        }

        /// Everything written so far, including a last line without '\n'.
        fn finish(self: *Self) !void {
            try self.writer.flush();
            if (self.line.items.len > 0) {
                try self.handleLine(std.mem.trim(u8, self.line.items, " \t\r"));
                self.line.clearRetainingCapacity();
            }
        }

        fn handleLine(self: *Self, line: []const u8) !void {
            if (self.done or !std.mem.startsWith(u8, line, "data:")) return;
            const data = std.mem.trim(u8, line["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.done = true;
                return;
            }
            if (data.len == 0) return;
            const Chunk = struct { choices: []const struct { delta: struct { content: ?[]const u8 = null } = .{} } = &.{} };
            const parsed = std.json.parseFromSliceLeaky(Chunk, self.arena, data, .{ .ignore_unknown_fields = true }) catch return;
            if (parsed.choices.len == 0) return;
            const delta = parsed.choices[0].delta.content orelse return;
            if (delta.len == 0) return;
            try self.full.appendSlice(self.arena, delta);
            on_chunk(self.ctx, delta);
        }
    };
}

/// `GET {base}/models`: the model ids, sorted.
pub fn listModels(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base_url: []const u8, api_key: []const u8, diag: *Diag) Error![]const []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const status = try exchange(io, gpa, arena, .GET, try endpoint(arena, base_url, "/models"), api_key, null, &out.writer, diag);
    if (status.class() != .success) return failFmt(arena, diag, "Models request returned {d} {s}", .{ @intFromEnum(status), status.phrase() orelse "" });
    const Resp = struct { data: []const struct { id: []const u8 } = &.{} };
    const parsed = std.json.parseFromSliceLeaky(Resp, arena, out.written(), .{ .ignore_unknown_fields = true }) catch
        return fail(diag, "Parse error: unexpected response from the endpoint");
    if (parsed.data.len == 0) return fail(diag, "No models returned by the endpoint");
    const ids = try arena.alloc([]const u8, parsed.data.len);
    for (parsed.data, ids) |m, *id| id.* = m.id;
    std.mem.sort([]const u8, ids, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return ids;
}

// ---- reasoning leaks -------------------------------------------------------------------

/// Remove inline reasoning blocks (`<think>…</think>`, `<reasoning>…</reasoning>`,
/// gemma's `<|channel>thought…<channel|>`). An unterminated opener drops
/// everything after it (the whole answer was reasoning).
pub fn stripReasoning(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const blocks = [_][2][]const u8{
        .{ "<think>", "</think>" },
        .{ "<reasoning>", "</reasoning>" },
        .{ "<|channel>thought", "<channel|>" },
    };
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, raw);
    for (blocks) |b| {
        while (std.mem.indexOf(u8, s.items, b[0])) |start| {
            if (std.mem.indexOfPos(u8, s.items, start, b[1])) |close| {
                try s.replaceRange(arena, start, close + b[1].len - start, "");
            } else {
                s.shrinkRetainingCapacity(start);
            }
        }
    }
    return std.mem.trim(u8, s.items, " \t\r\n");
}

/// Does this look like the model's scratchpad rather than the transformed
/// text? Scored on shape (two points trigger the retry); a false positive
/// only costs one extra round-trip.
pub fn looksLikeReasoning(output: []const u8, input: ?[]const u8) bool {
    const meta = [_][]const u8{
        "the user wants",          "the user is asking",  "thinking process",      "**analysis:**",
        "self-correction",         "drafting the",        "**drafting",            "final check against",
        "**final review",          "**translation strategy", "**breakdown",        "**original text:**",
        "original text:",          "analyze the input",   "analyzing the input",   "revising the sentences",
        "here is the corrected",   "here's the corrected", "i need to translate",  "i should translate",
        "let me translate",
    };
    var score: u8 = 0;
    for (meta) |m| if (containsIgnoreCase(output, m)) {
        score += 2;
        break;
    };

    var arrows: usize = 0;
    var quoted_items: usize = 0;
    var bullets: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if ((std.mem.indexOf(u8, line, "->") != null or std.mem.indexOf(u8, line, "\u{2192}") != null) and std.mem.indexOfScalar(u8, line, '"') != null) arrows += 1;
        const t = std.mem.trimStart(u8, line, " \t");
        const rest = std.mem.trimStart(u8, t, "0123456789");
        if (rest.len < t.len and rest.len > 0 and rest[0] == '.' and std.mem.startsWith(u8, std.mem.trimStart(u8, rest[1..], " \t"), "\"")) quoted_items += 1;
        if (std.mem.startsWith(u8, t, "*   ")) bullets += 1;
    }
    if (arrows >= 2) score += 2;
    if (quoted_items >= 2) score += 1;
    if (bullets >= 3) score += 1;
    if (input) |in| {
        const i = std.unicode.utf8CountCodepoints(in) catch in.len;
        const o = std.unicode.utf8CountCodepoints(output) catch output.len;
        if (i > 0 and o > i * 5 / 2) score += 1;
    }
    return score >= 2;
}

fn containsIgnoreCase(haystack: []const u8, lower_needle: []const u8) bool {
    if (lower_needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + lower_needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..lower_needle.len], lower_needle)) return true;
    }
    return false;
}

// ---- tests -----------------------------------------------------------------------------

test stripReasoning {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Hello", try stripReasoning(a, "<think>plan</think> Hello "));
    try std.testing.expectEqualStrings("A B", try stripReasoning(a, "A <reasoning>x</reasoning>B"));
    try std.testing.expectEqualStrings("Out", try stripReasoning(a, "Out <think>never closed"));
    try std.testing.expectEqualStrings("", try stripReasoning(a, "<|channel>thought still thinking"));
}

test looksLikeReasoning {
    try std.testing.expect(!looksLikeReasoning("I have completed the item you requested.", "done thx"));
    try std.testing.expect(looksLikeReasoning("The user wants me to translate this.\nHola", "Hello"));
    try std.testing.expect(looksLikeReasoning("\"dont\" -> \"don't\"\n\"teh\" -> \"the\"", "dont teh"));
    try std.testing.expect(!looksLikeReasoning("a -> b", "a"));
}

test "prompts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = (try builtinPrompt(a, "translate", "Spanish", .balanced)).?;
    try std.testing.expect(std.mem.indexOf(u8, t, "fluent Spanish,") != null);
    try std.testing.expect((try builtinPrompt(a, "nope", null, .balanced)) == null);
    const ins = try instructionPrompt(a, "make it \"pop\"");
    try std.testing.expect(std.mem.indexOf(u8, ins, "\"make it 'pop'\"") != null);
}

test buildBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try buildBody(a, .{
        .profile = settings.default_profile,
        .system = "sys",
        .user = .{ .image_with_text = .{ .text = ocr_user_text, .png = "PNG" } },
    }, false, true);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try std.testing.expectEqualStrings("gemma4:e4b", v.object.get("model").?.string);
    const content = v.object.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("data:image/png;base64,UE5H", content[1].object.get("image_url").?.object.get("url").?.string);
    try std.testing.expectEqual(false, v.object.get("think").?.bool);
    try std.testing.expectEqual(true, v.object.get("stream").?.bool);
}

test "SSE sink" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Collect = struct {
        n: usize = 0,
        fn chunk(self: *@This(), _: []const u8) void {
            self.n += 1;
        }
    };
    var c: Collect = .{};
    var sink: SseSink(*Collect, Collect.chunk) = .{ .arena = arena.allocator(), .ctx = &c };
    sink.init();
    try sink.writer.writeAll("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"con");
    try sink.writer.writeAll("tent\":\"lo\"}}]}\n\ndata: [DONE]\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"X\"}}]}\n");
    try sink.finish();
    try std.testing.expectEqualStrings("Hello", sink.full.items);
    try std.testing.expectEqual(@as(usize, 2), c.n);
}

test "SSE sink: streamed from a reader, deltas as they arrive" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Collect = struct {
        n: usize = 0,
        fn chunk(self: *@This(), _: []const u8) void {
            self.n += 1;
        }
    };
    var c: Collect = .{};
    var sink: SseSink(*Collect, Collect.chunk) = .{ .arena = arena.allocator(), .ctx = &c };
    sink.init();
    // As the HTTP client does it (this asserted with an empty buffer).
    var r: std.Io.Reader = .fixed("data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n\n");
    _ = try r.streamRemaining(&sink.writer);
    // The delta is out before any flush (its line ended; only the blank line waits).
    try std.testing.expectEqual(@as(usize, 1), c.n);
    try sink.finish();
    try std.testing.expectEqualStrings("A", sink.full.items);
}
