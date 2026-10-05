//! Local OpenAI-compatible transcription server (optional), as in the Tauri
//! GhostPen: other local tools (e.g. an agent that receives voice notes)
//! transcribe through GhostPen's own whisper model instead of running a
//! second one.
//!
//! It is also the model service (`model_server.zig`): chat, vision and
//! embeddings from the built-in models, for other local apps (GhostReel).
//!
//! On by default, on what Settings → Model & speech service says
//! (`127.0.0.1:8771`: this machine only); `GHOSTPEN_MODEL_SERVER=0` turns it
//! off, `GHOSTPEN_STT_BIND` overrides the setting. `GHOSTPEN_STT_SERVER=1`
//! (as before) also loads the whisper model at startup. It serves:
//!
//! - `POST /v1/audio/transcriptions`: the OpenAI Whisper API shape: a
//!   multipart `file` (any format ffmpeg reads), optional `language` and
//!   `response_format`: `json` (default, `{"text": …}`), `text` (the raw
//!   transcript), `verbose_json` (plus language, duration and timestamped
//!   `segments: [{id, start, end, text}]`), `srt`, `vtt`.
//! - `GET /v1/models`: the served model and these capabilities.
//! - `GET /health`: `ok`.
//! - `GET /metrics`: the built-in model's performance counters (tokens,
//!   wall-clock and tok/s of the totals, the last request and the running
//!   one; model_server.zig).
//!
//! The model is `GHOSTPEN_STT_MODEL`, else Settings → Captions (read per
//! request); `GHOSTPEN_STT_LANGUAGE` is the default language (`auto`). It
//! shares the resident model and its lock with captions and dictation, so a
//! voice note never loads a second copy into GPU memory. Audio is decoded by
//! `ffmpeg`, which must be installed.

const std = @import("std");
const main = @import("main.zig");
const models = @import("models.zig");
const model_server = @import("model_server.zig");

const log = std.log.scoped(.stt_server);
const gpa = std.heap.smp_allocator;

/// Uploads larger than this are refused (an hour of opus is ~30 MB).
const max_body = 200 * 1024 * 1024;

const Config = struct {
    model_override: ?[]const u8,
    language: []const u8,
};

var config: Config = .{ .model_override = null, .language = "auto" };

var env_map: *const std.process.Environ.Map = undefined;
/// Whisper loaded at startup (GHOSTPEN_STT_SERVER=1), else on the first request.
var preload = false;

/// Start the server (see the top of the file). Never fails: problems are logged.
pub fn maybeStart(io: std.Io, env: *const std.process.Environ.Map) void {
    env_map = env;
    const stt_flag = if (env.get("GHOSTPEN_STT_SERVER")) |f| std.mem.eql(u8, f, "1") else false;
    const off = if (env.get("GHOSTPEN_MODEL_SERVER")) |f| std.mem.eql(u8, f, "0") else false;
    if (off and !stt_flag) return;
    preload = stt_flag;
    // Where it listens: GHOSTPEN_STT_BIND overrides, else Settings →
    // Model & speech service (host:port; this machine only by default).
    const bind: []const u8 = if (env.get("GHOSTPEN_STT_BIND")) |b|
        (gpa.dupe(u8, b) catch return)
    else blk: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const s = main.shared.get(io, arena.allocator()) catch break :blk "127.0.0.1:8771";
        break :blk std.fmt.allocPrint(gpa, "{s}:{d}", .{ s.server.host, s.server.port }) catch return;
    };
    config = .{
        .model_override = if (env.get("GHOSTPEN_STT_MODEL")) |m| (if (std.mem.trim(u8, m, " ").len > 0) gpa.dupe(u8, m) catch null else null) else null,
        .language = gpa.dupe(u8, env.get("GHOSTPEN_STT_LANGUAGE") orelse "auto") catch "auto",
    };
    const address = parseBind(bind) catch {
        log.warn("invalid GHOSTPEN_STT_BIND \"{s}\": not starting", .{bind});
        return;
    };
    const t = std.Thread.spawn(.{}, serve, .{ io, address, bind }) catch |err| {
        log.warn("can't start: {s}", .{@errorName(err)});
        return;
    };
    t.detach();
}

/// `host:port` (IPv4 or `[ipv6]:port`).
fn parseBind(bind: []const u8) !std.Io.net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return error.InvalidBind;
    const port = try std.fmt.parseInt(u16, bind[colon + 1 ..], 10);
    var host = bind[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    return std.Io.net.IpAddress.parse(host, port);
}

/// The model the server was started with (GHOSTPEN_STT_MODEL), if any.
pub fn modelOverride() ?[]const u8 {
    return config.model_override;
}

/// The model to serve now: the override, else the live captions setting.
fn currentModel(arena: std.mem.Allocator) []const u8 {
    if (config.model_override) |m| return m;
    const s = main.shared.get(main.io, arena) catch return "base";
    return s.captions.model;
}

fn serve(io: std.Io, address: std.Io.net.IpAddress, bind: []const u8) void {
    // GHOSTPEN_STT_SERVER=1: load the model first so the first request isn't
    // slow; not downloaded: don't serve (every request would fail).
    if (preload) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const model = currentModel(arena.allocator());
        models.ensure(io, gpa, model) catch |err| {
            log.warn("can't load the whisper model \"{s}\" ({s}): not starting (download it in Settings → Live Captions)", .{ model, @errorName(err) });
            return;
        };
        log.info("listening on http://{s} (model {s})", .{ bind, model });
    }
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        log.warn("can't listen on {s}: {s}", .{ bind, @errorName(err) });
        return;
    };
    defer server.deinit(io);
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        // Other apps connect over loopback whatever the bind address.
        const url = std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}", .{address.getPort()}) catch return;
        model_server.writeDiscovery(io, env_map, url, currentModel(arena.allocator()));
        log.info("model service on http://{s}", .{bind});
    }
    while (true) {
        const stream = server.accept(io) catch |err| {
            log.warn("accept: {s}", .{@errorName(err)});
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConnection, .{ io, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    while (true) {
        var request = http.receiveHead() catch return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        handle(io, arena.allocator(), &request) catch return;
        if (!request.head.keep_alive) return;
    }
}

/// Transcriptions running or waiting for the model.
var active: std.atomic.Value(u32) = .init(0);
const max_active = 2;

const Reply = model_server.Reply;

fn handle(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    // A POST with neither Content-Length nor chunked encoding has no body,
    // but std.http.Server's respond would read one until the client hangs up
    // (`curl -X POST .../unload` never got an answer): answer and close.
    if (request.head.method.requestHasBody() and request.head.content_length == null and request.head.transfer_encoding == .none)
        request.head.keep_alive = false;
    const path = if (std.mem.indexOfScalar(u8, request.head.target, '?')) |q| request.head.target[0..q] else request.head.target;
    const reply: Reply = if (std.mem.eql(u8, path, "/health") and request.head.method == .GET)
        .{ .body = "ok", .content_type = "text/plain; charset=utf-8" }
    else if (std.mem.eql(u8, path, "/v1/models") and request.head.method == .GET)
        .{ .body = try modelsBody(arena) }
    else if (std.mem.eql(u8, path, "/props") and request.head.method == .GET)
        try model_server.propsReply(arena)
    else if (std.mem.eql(u8, path, "/slots") and request.head.method == .GET)
        try model_server.slotsReply(arena)
    else if (std.mem.eql(u8, path, "/metrics") and request.head.method == .GET)
        try model_server.metricsReply(io, arena)
    else if (std.mem.eql(u8, path, "/unload") and request.head.method == .POST)
        try model_server.unloadReply(io, arena, try readJsonBody(arena, request) orelse "")
    else if (std.mem.eql(u8, path, "/v1/embeddings") and request.head.method == .POST)
        try model_server.embeddingsReply(io, arena, try readJsonBody(arena, request) orelse return error.BadBody)
    else if (std.mem.eql(u8, path, "/v1/chat/completions") and request.head.method == .POST) blk: {
        const body = try readJsonBody(arena, request) orelse return error.BadBody;
        break :blk (try model_server.chatReply(io, arena, request, body)) orelse return; // streamed
    } else if (std.mem.eql(u8, path, "/v1/audio/transcriptions") and request.head.method == .POST) blk: {
        // Each request can hold hundreds of MB (the upload and its PCM) while
        // it waits for the one whisper model: a few at a time.
        if (active.fetchAdd(1, .acq_rel) >= max_active) {
            _ = active.fetchSub(1, .acq_rel);
            try request.respond("busy: too many transcriptions at once, retry later", .{
                .status = .service_unavailable,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            });
            return error.Busy; // the unread body: close the connection
        }
        defer _ = active.fetchSub(1, .acq_rel);
        break :blk transcriptionReply(io, arena, request) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => .{ .status = .internal_server_error, .body = @errorName(err), .content_type = "text/plain; charset=utf-8" },
        };
    } else .{ .status = .not_found, .body = "not found", .content_type = "text/plain; charset=utf-8" };
    try request.respond(reply.body, .{
        .status = reply.status,
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{.{ .name = "content-type", .value = reply.content_type }},
    });
}

/// The whisper model first (clients read its `segments` capability from the
/// first entry), then the built-in chat and embedding models.
fn modelsBody(arena: std.mem.Allocator) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &w.writer };
    try js.beginObject();
    try js.objectField("object");
    try js.write("list");
    try js.objectField("data");
    try js.beginArray();
    try js.write(.{
        .id = currentModel(arena),
        .object = "model",
        .owned_by = "ghostpen",
        .capabilities = .{
            .response_formats = .{ "json", "text", "verbose_json", "srt", "vtt" },
            .segments = true,
        },
    });
    for (try model_server.modelEntries(arena)) |e| try js.write(e);
    try js.endArray();
    try js.endObject();
    return w.written();
}

/// A JSON request body (chat requests carry base64 images: up to 40 MB).
fn readJsonBody(arena: std.mem.Allocator, request: *std.http.Server.Request) !?[]const u8 {
    const limit = 40 * 1024 * 1024;
    if (request.head.content_length) |len| if (len > limit) return null;
    // No length and not chunked: HTTP says there's no body (don't wait for one).
    if (request.head.content_length == null and request.head.transfer_encoding == .none) return "";
    var body_buf: [64 * 1024]u8 = undefined;
    const r = request.readerExpectContinue(&body_buf) catch return null;
    return r.allocRemaining(arena, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => null,
    };
}

fn badRequest(message: []const u8) Reply {
    return .{ .status = .bad_request, .body = message, .content_type = "text/plain; charset=utf-8" };
}

fn transcriptionReply(io: std.Io, arena: std.mem.Allocator, request: *std.http.Server.Request) !Reply {
    const content_type = request.head.content_type orelse return badRequest("expected multipart/form-data");
    // The head points into the connection's read buffer, which reading the
    // body reuses: copy what's needed first.
    const boundary = try arena.dupe(u8, multipartBoundary(content_type) orelse return badRequest("expected multipart/form-data"));
    if (request.head.content_length) |len| if (len > max_body) return badRequest("the upload is too large");
    var body_buf: [64 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&body_buf) catch return badRequest("can't read the body");
    const body = body_reader.allocRemaining(arena, .limited(max_body)) catch |err| return switch (err) {
        error.OutOfMemory => err,
        error.StreamTooLong => badRequest("the upload is too large"),
        else => badRequest("can't read the body"),
    };

    var audio: ?[]const u8 = null;
    var language: []const u8 = config.language;
    var format: []const u8 = "json";
    var parts = Multipart{ .body = body, .boundary = boundary };
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.name, "file")) {
            audio = part.data;
        } else if (std.mem.eql(u8, part.name, "language")) {
            const v = std.mem.trim(u8, part.data, " \t\r\n");
            if (v.len > 0) language = v;
        } else if (std.mem.eql(u8, part.name, "response_format")) {
            const v = std.mem.trim(u8, part.data, " \t\r\n");
            if (v.len > 0) format = try std.ascii.allocLowerString(arena, v);
        }
    }
    const data = audio orelse return badRequest("missing 'file' field");
    const samples = decodeToPcm16k(io, arena, data) catch |err| return .{
        .status = .bad_request,
        .body = try std.fmt.allocPrint(arena, "audio decode failed: {s} (is ffmpeg installed?)", .{@errorName(err)}),
        .content_type = "text/plain; charset=utf-8",
    };
    const model = currentModel(arena);
    const transcript = try models.transcribeSegments(io, gpa, arena, model, samples, language);
    const duration = @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(models.sample_rate));

    if (std.mem.eql(u8, format, "text")) return .{ .body = try transcript.text(arena), .content_type = "text/plain; charset=utf-8" };
    if (std.mem.eql(u8, format, "srt")) return .{ .body = try subtitles(arena, transcript.segments, .srt), .content_type = "application/x-subrip" };
    if (std.mem.eql(u8, format, "vtt")) return .{ .body = try subtitles(arena, transcript.segments, .vtt), .content_type = "text/vtt" };
    if (std.mem.eql(u8, format, "verbose_json")) return .{ .body = try verboseJson(arena, transcript, duration) };
    return .{ .body = try std.json.Stringify.valueAlloc(arena, .{ .text = try transcript.text(arena) }, .{}) };
}

/// `multipart/form-data; boundary=XYZ` → `XYZ` (quotes removed).
fn multipartBoundary(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(std.mem.trim(u8, content_type, " "), "multipart/form-data")) return null;
    var it = std.mem.splitScalar(u8, content_type, ';');
    while (it.next()) |param| {
        const p = std.mem.trim(u8, param, " ");
        if (std.ascii.startsWithIgnoreCase(p, "boundary=")) {
            const v = std.mem.trim(u8, p["boundary=".len..], "\"");
            return if (v.len > 0 and v.len <= 200) v else null;
        }
    }
    return null;
}

/// The parts of a multipart/form-data body.
const Multipart = struct {
    body: []const u8,
    boundary: []const u8,
    pos: usize = 0,

    const Part = struct { name: []const u8, data: []const u8 };

    fn next(self: *Multipart) ?Part {
        var delim_buf: [256]u8 = undefined;
        const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{self.boundary}) catch return null;
        while (true) {
            const start = std.mem.indexOfPos(u8, self.body, self.pos, delim) orelse return null;
            var p = start + delim.len;
            if (std.mem.startsWith(u8, self.body[p..], "--")) return null; // closing delimiter
            if (std.mem.startsWith(u8, self.body[p..], "\r\n")) p += 2;
            const headers_end = std.mem.indexOfPos(u8, self.body, p, "\r\n\r\n") orelse return null;
            const headers = self.body[p..headers_end];
            const data_start = headers_end + 4;
            var end_buf: [260]u8 = undefined;
            const end_delim = std.fmt.bufPrint(&end_buf, "\r\n--{s}", .{self.boundary}) catch return null;
            const data_end = std.mem.indexOfPos(u8, self.body, data_start, end_delim) orelse return null;
            self.pos = data_end + 2;
            if (partName(headers)) |name| return .{ .name = name, .data = self.body[data_start..data_end] };
        }
    }

    /// `name="…"` from the Content-Disposition header (not `filename="…"`).
    fn partName(headers: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            if (!std.ascii.startsWithIgnoreCase(line, "content-disposition:")) continue;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, "name=\"")) |i| : (from = i + 1) {
                if (i == 0 or (line[i - 1] != ' ' and line[i - 1] != ';')) continue;
                const s = i + "name=\"".len;
                const e = std.mem.indexOfScalarPos(u8, line, s, '"') orelse return null;
                return line[s..e];
            }
        }
        return null;
    }
};

/// Any audio ffmpeg reads → 16 kHz mono f32 (what whisper takes).
fn decodeToPcm16k(io: std.Io, arena: std.mem.Allocator, bytes: []const u8) ![]const f32 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    // Feed stdin from another thread: ffmpeg's full stdout pipe would
    // otherwise block it while we block on its stdin.
    const Feed = struct {
        fn run(i: std.Io, file: std.Io.File, data: []const u8) void {
            file.writeStreamingAll(i, data) catch {};
            file.close(i);
        }
    };
    const stdin = child.stdin.?;
    child.stdin = null; // closed by the feeder
    const feeder = std.Thread.spawn(.{}, Feed.run, .{ io, stdin, bytes }) catch |err| {
        stdin.close(io);
        child.kill(io);
        return err;
    };
    var buf: [64 * 1024]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    // f32 samples straight into a 4-aligned buffer (no second copy). At most
    // 2 GiB (~9 h of audio).
    var pcm: std.array_list.Aligned(u8, .@"4") = .empty;
    r.interface.appendRemainingAligned(arena, .@"4", &pcm, .limited(1 << 31)) catch |err| {
        // Kill first: ffmpeg blocked on a full stdout would keep the feeder
        // blocked on its stdin, and the join would never return.
        child.kill(io);
        feeder.join();
        return err;
    };
    feeder.join();
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.FfmpegFailed;
    const n = pcm.items.len / 4;
    const samples: []f32 = @as([*]f32, @ptrCast(pcm.items.ptr))[0..n];
    if (@import("builtin").cpu.arch.endian() != .little) {
        for (samples) |*s| s.* = @bitCast(@byteSwap(@as(u32, @bitCast(s.*))));
    }
    return samples;
}

fn verboseJson(arena: std.mem.Allocator, t: models.Transcript, duration: f64) ![]const u8 {
    const Seg = struct { id: usize, start: f64, end: f64, text: []const u8 };
    const segs = try arena.alloc(Seg, t.segments.len);
    for (t.segments, segs, 0..) |s, *o, i| o.* = .{ .id = i, .start = s.start, .end = s.end, .text = std.mem.trim(u8, s.text, " \t\r\n") };
    return std.json.Stringify.valueAlloc(arena, .{
        .task = "transcribe",
        .language = t.language,
        .duration = duration,
        .text = try t.text(arena),
        .segments = segs,
    }, .{});
}

const SubtitleFormat = enum { srt, vtt };

fn subtitles(arena: std.mem.Allocator, segments: []const models.Segment, format: SubtitleFormat) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const sep: u8 = if (format == .srt) ',' else '.';
    if (format == .vtt) try w.writeAll("WEBVTT\n\n");
    for (segments, 0..) |seg, i| {
        if (format == .srt) try w.print("{d}\n", .{i + 1});
        try writeTime(w, seg.start, sep);
        try w.writeAll(" --> ");
        try writeTime(w, seg.end, sep);
        try w.print("\n{s}\n\n", .{std.mem.trim(u8, seg.text, " \t\r\n")});
    }
    return out.written();
}

/// `HH:MM:SS<sep>mmm`.
fn writeTime(w: *std.Io.Writer, seconds: f64, sep: u8) !void {
    const ms: u64 = @intFromFloat(@round(@max(seconds, 0) * 1000));
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>3}", .{ ms / 3_600_000, ms % 3_600_000 / 60_000, ms % 60_000 / 1000, sep, ms % 1000 });
}

test subtitles {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]models.Segment{
        .{ .start = 0, .end = 2.5, .text = " Hello there." },
        .{ .start = 3661.04, .end = 3662, .text = " Second line" },
    };
    try std.testing.expectEqualStrings(
        "1\n00:00:00,000 --> 00:00:02,500\nHello there.\n\n2\n01:01:01,040 --> 01:01:02,000\nSecond line\n\n",
        try subtitles(a, &segs, .srt),
    );
    try std.testing.expect(std.mem.startsWith(u8, try subtitles(a, &segs, .vtt), "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nHello there.\n"));
    const t: models.Transcript = .{ .segments = &segs, .language = "en" };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try verboseJson(a, t, 3662), .{});
    try std.testing.expectEqualStrings("Hello there. Second line", v.object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 1), v.object.get("segments").?.array.items[1].object.get("id").?.integer);
}

test Multipart {
    const body = "--XX\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n" ++
        "--XX\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.ogg\"\r\nContent-Type: audio/ogg\r\n\r\nOGG\x00DATA\r\n" ++
        "--XX\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n--XX--\r\n";
    var m = Multipart{ .body = body, .boundary = "XX" };
    const a = m.next().?;
    try std.testing.expectEqualStrings("model", a.name);
    const b = m.next().?;
    try std.testing.expectEqualStrings("file", b.name);
    try std.testing.expectEqualStrings("OGG\x00DATA", b.data);
    try std.testing.expectEqualStrings("text", m.next().?.data);
    try std.testing.expect(m.next() == null);
    try std.testing.expectEqualStrings("abc", multipartBoundary("multipart/form-data; boundary=\"abc\"").?);
    try std.testing.expect(multipartBoundary("application/json") == null);
}

test parseBind {
    _ = try parseBind("0.0.0.0:8771");
    _ = try parseBind("[::1]:9000");
    try std.testing.expectError(error.InvalidBind, parseBind("nocolon"));
}
