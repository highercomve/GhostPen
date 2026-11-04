//! `ghostpen say [TEXT...]`: speak through GhostPen's built-in voice, for
//! scripts and agents ("tell me when the build is done").
//!
//! A running GhostPen speaks it: its voice is already loaded, and what
//! several agents say is queued instead of talking over each other
//! (POST /speak on the model service, src/stt_server.zig). Without one, or
//! with `--local`, this process loads the voice and speaks (the first run
//! downloads it, as `--say` always did).
const std = @import("std");
const tts = @import("tts.zig");
const model_server = @import("model_server.zig");

pub const usage =
    \\Usage: ghostpen say [OPTIONS] [TEXT...]
    \\
    \\Speak TEXT aloud with GhostPen's built-in voice (read from stdin when
    \\not given). A running GhostPen speaks it, one saying after another;
    \\else this command loads the voice itself.
    \\
    \\Options:
    \\  --lang <lang>     Language: en-us, es, fr, ... or "French" (default: guessed)
    \\  --voice <id>      A voice, e.g. af_heart, ef_dora (default: the language's)
    \\  --model <id>      The voice model (default: the one downloaded)
    \\  --local           Speak in this process, even when GhostPen runs
    \\  -q, --quiet       Print nothing on success
    \\  -h, --help        This help
    \\
    \\Example: echo "The tests passed" | ghostpen say
    \\
;

pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8, tts_ready: bool) u8 {
    var req: tts.Request = .{ .text = "" };
    var local = false;
    var quiet = false;
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eql = std.mem.eql;
        if (eql(u8, a, "-h") or eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (eql(u8, a, "--local")) {
            local = true;
        } else if (eql(u8, a, "-q") or eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (eql(u8, a, "--lang") or eql(u8, a, "--voice") or eql(u8, a, "--model")) {
            if (i + 1 >= args.len) {
                std.debug.print("error: {s} needs a value\n\n{s}", .{ a, usage });
                return 2;
            }
            i += 1;
            if (eql(u8, a, "--lang")) req.lang = args[i] else if (eql(u8, a, "--voice")) req.voice = args[i] else req.model = args[i];
        } else {
            words.append(arena, a) catch return 1;
        }
    }
    req.text = if (words.items.len > 0)
        std.mem.join(arena, " ", words.items) catch return 1
    else
        readStdin(io, arena) catch |err| {
            std.debug.print("error: can't read stdin ({s})\n", .{@errorName(err)});
            return 1;
        };
    req.text = std.mem.trim(u8, req.text, " \t\r\n");
    if (req.text.len == 0) {
        std.debug.print("error: nothing to say (give TEXT or pipe it on stdin)\n\n{s}", .{usage});
        return 2;
    }

    if (!local) switch (viaApp(io, gpa, arena, env, req)) {
        .said => |voice| {
            if (!quiet) std.debug.print("Said it ({s}, through GhostPen).\n", .{voice});
            return 0;
        },
        .failed => |message| {
            std.debug.print("error: {s}\n", .{message});
            return 1;
        },
        .no_app => {}, // speak here
    };

    if (!tts_ready) {
        std.debug.print("error: no data directory for the voice\n", .{});
        return 1;
    }
    defer @import("oriel").tts.deinit();
    const r = tts.say(gpa, req) catch return 1;
    defer {
        gpa.free(r.voice);
        gpa.free(r.lang);
        gpa.free(r.backend);
    }
    if (!quiet) std.debug.print("Said it ({s}, {s}, on {s}): first audio in {d} ms (model load {d} ms), {d:.1} s of audio synthesized in {d} ms.\n", .{
        r.voice, r.lang, r.backend, r.first_audio_ms, r.load_ms, r.audio_s, r.synth_ms,
    });
    return 0;
}

fn readStdin(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &buf);
    return r.interface.allocRemaining(arena, .limited(1024 * 1024));
}

const Outcome = union(enum) {
    /// The running app said it (with this voice).
    said: []const u8,
    /// The app answered with an error worth showing (busy, no voice downloaded).
    failed: []const u8,
    /// No running GhostPen (or one too old for /speak): speak here.
    no_app,
};

/// Ask the running GhostPen (its model service, found through the discovery
/// file) to speak; waits until it has.
fn viaApp(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, req: tts.Request) Outcome {
    const path = model_server.discoveryPath(arena, env) orelse return .no_app;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return .no_app;
    const Discovery = struct { app: []const u8 = "", url: []const u8 = "" };
    const d = std.json.parseFromSliceLeaky(Discovery, arena, bytes, .{ .ignore_unknown_fields = true }) catch return .no_app;
    if (!std.mem.eql(u8, d.app, "GhostPen") or d.url.len == 0) return .no_app;
    const url = std.fmt.allocPrint(arena, "{s}/speak", .{std.mem.trimEnd(u8, d.url, "/")}) catch return .no_app;
    const body = std.json.Stringify.valueAlloc(arena, .{ .input = req.text, .lang = req.lang, .voice = req.voice, .model = req.model }, .{}) catch return .no_app;

    var answer: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &answer.writer,
    }) catch return .no_app; // not running (a stale discovery file), or gone
    const text = answer.written();
    // An older GhostPen has no /speak: speak here instead.
    if (res.status == .not_found) return .no_app;
    if (res.status.class() != .success) return .{ .failed = errorMessage(arena, text) };
    const Said = struct { voice: []const u8 = "" };
    const said = std.json.parseFromSliceLeaky(Said, arena, text, .{ .ignore_unknown_fields = true }) catch return .{ .said = "" };
    return .{ .said = said.voice };
}

/// The message of an OpenAI-style error body ({"error":{"message":...}}), else the body.
fn errorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const E = struct { @"error": struct { message: []const u8 = "" } = .{} };
    const e = std.json.parseFromSliceLeaky(E, arena, body, .{ .ignore_unknown_fields = true }) catch return body;
    return if (e.@"error".message.len > 0) e.@"error".message else body;
}
