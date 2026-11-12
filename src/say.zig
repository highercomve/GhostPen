//! `ghostpen say [TEXT...]`: speak through GhostPen's built-in voice, for
//! scripts and agents ("tell me when the build is done").
//!
//! A running GhostPen speaks it: its voice is already loaded, and what
//! several agents say is queued instead of talking over each other
//! (POST /speak on the model service, src/stt_server.zig). Without one, or
//! with `--local`, this process loads the voice and speaks (the first run
//! downloads it, as `--say` always did).
//!
//! `--out FILE` writes the speech to a WAV file instead of playing it ("-":
//! stdout), for scripts that send it on (a voice note). A running GhostPen
//! makes it too (POST /v1/audio/speech, the OpenAI speech API); without one,
//! or with `--local`, this process synthesizes it.
const std = @import("std");
const tts = @import("tts.zig");
const wav = @import("wav.zig");
const model_server = @import("model_server.zig");

pub const usage =
    \\Usage: ghostpen say [OPTIONS] [TEXT...]
    \\
    \\Speak TEXT aloud with GhostPen's built-in voice (read from stdin when
    \\not given). A running GhostPen speaks it, one saying after another;
    \\else this command loads the voice itself. With --out the speech goes to
    \\a WAV file (16-bit mono, 24 kHz) and nothing is played.
    \\
    \\Options:
    \\  --lang <lang>     Language: en-us, es, fr, ... or "French" (default: guessed)
    \\  --voice <id>      A voice, e.g. af_heart, ef_dora (default: the language's)
    \\  --model <id>      The voice model (default: the one downloaded)
    \\  --speed <x>       Speaking rate, 0.25 to 4 (default: 1)
    \\  --out <file>      Write a WAV file instead of speaking; "-" is stdout
    \\  --local           Speak (or synthesize) in this process, even when GhostPen runs
    \\  -q, --quiet       Print nothing on success
    \\  -h, --help        This help
    \\
    \\Examples: echo "The tests passed" | ghostpen say
    \\          ghostpen say --lang es --out nota.wav "Hola, esto es una prueba"
    \\
;

pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8, tts_ready: bool) u8 {
    var req: tts.Request = .{ .text = "" };
    var local = false;
    var quiet = false;
    var out: ?[]const u8 = null;
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
        } else if (eql(u8, a, "--lang") or eql(u8, a, "--voice") or eql(u8, a, "--model") or eql(u8, a, "--out") or eql(u8, a, "--speed")) {
            if (i + 1 >= args.len) {
                std.debug.print("error: {s} needs a value\n\n{s}", .{ a, usage });
                return 2;
            }
            i += 1;
            if (eql(u8, a, "--lang")) {
                req.lang = args[i];
            } else if (eql(u8, a, "--voice")) {
                req.voice = args[i];
            } else if (eql(u8, a, "--model")) {
                req.model = args[i];
            } else if (eql(u8, a, "--out")) {
                out = args[i];
            } else {
                req.speed = std.fmt.parseFloat(f32, args[i]) catch 0;
                if (!(req.speed >= 0.25 and req.speed <= 4.0)) {
                    std.debug.print("error: --speed takes a number from 0.25 to 4\n", .{});
                    return 2;
                }
            }
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

    if (out) |path| return writeSpeech(io, gpa, arena, env, req, path, local, quiet, tts_ready);

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

/// What the running GhostPen answered.
const Answer = struct { status: std.http.Status, body: []const u8 };

/// POST `payload` (JSON) to `route` on the running GhostPen's model service
/// (found through the discovery file); waits for the answer. Null: no
/// running GhostPen (or a stale discovery file).
fn postToApp(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, route: []const u8, payload: []const u8) ?Answer {
    const path = model_server.discoveryPath(arena, env) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const Discovery = struct { app: []const u8 = "", url: []const u8 = "" };
    const d = std.json.parseFromSliceLeaky(Discovery, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, d.app, "GhostPen") or d.url.len == 0) return null;
    const url = std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, d.url, "/"), route }) catch return null;

    var answer: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &answer.writer,
    }) catch return null; // not running (a stale discovery file), or gone
    return .{ .status = res.status, .body = answer.written() };
}

/// Ask the running GhostPen (its model service, found through the discovery
/// file) to speak; waits until it has.
fn viaApp(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, req: tts.Request) Outcome {
    const body = std.json.Stringify.valueAlloc(arena, .{ .input = req.text, .lang = req.lang, .voice = req.voice, .model = req.model }, .{}) catch return .no_app;
    const res = postToApp(io, gpa, arena, env, "/speak", body) orelse return .no_app;
    // An older GhostPen has no /speak: speak here instead.
    if (res.status == .not_found) return .no_app;
    if (res.status.class() != .success) return .{ .failed = errorMessage(arena, res.body) };
    const Said = struct { voice: []const u8 = "" };
    const said = std.json.parseFromSliceLeaky(Said, arena, res.body, .{ .ignore_unknown_fields = true }) catch return .{ .said = "" };
    return .{ .said = said.voice };
}

/// `--out`: the speech as a WAV file (or stdout for "-"), made by the running
/// GhostPen when there is one, else here. Exit code.
fn writeSpeech(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, req: tts.Request, path: []const u8, local: bool, quiet: bool, tts_ready: bool) u8 {
    var wav_bytes: []const u8 = "";
    var made_by: []const u8 = "";
    if (!local) switch (viaAppWav(io, gpa, arena, env, req)) {
        .made => |bytes| {
            wav_bytes = bytes;
            made_by = "through GhostPen";
        },
        .failed => |message| {
            std.debug.print("error: {s}\n", .{message});
            return 1;
        },
        .no_app => {},
    };
    if (wav_bytes.len == 0) {
        if (!tts_ready) {
            std.debug.print("error: no data directory for the voice\n", .{});
            return 1;
        }
        defer @import("oriel").tts.deinit();
        const audio = tts.synthesize(gpa, req, .print) catch return 1;
        defer audio.deinit(gpa);
        wav_bytes = wav.encodeMono(arena, audio.samples, audio.rate) catch |err| {
            std.debug.print("error: can't encode the audio ({s})\n", .{@errorName(err)});
            return 1;
        };
        made_by = std.fmt.allocPrint(arena, "{s}, {s}, on {s}: {d:.1} s of audio synthesized in {d} ms", .{ audio.voice, audio.lang, audio.backend, audio.audio_s, audio.synth_ms }) catch "here";
    }
    if (std.mem.eql(u8, path, "-")) {
        std.Io.File.stdout().writeStreamingAll(io, wav_bytes) catch |err| {
            std.debug.print("error: can't write to stdout ({s})\n", .{@errorName(err)});
            return 1;
        };
    } else {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = wav_bytes }) catch |err| {
            std.debug.print("error: can't write {s} ({s})\n", .{ path, @errorName(err) });
            return 1;
        };
    }
    if (!quiet) std.debug.print("Wrote {s} ({d} KB; {s}).\n", .{ if (std.mem.eql(u8, path, "-")) "stdout" else path, (wav_bytes.len + 512) / 1024, made_by });
    return 0;
}

const WavOutcome = union(enum) {
    /// The running app's WAV file.
    made: []const u8,
    /// The app answered with an error worth showing.
    failed: []const u8,
    /// No running GhostPen (or one too old for the endpoint): synthesize here.
    no_app,
};

/// Ask the running GhostPen for the speech (POST /v1/audio/speech, WAV).
fn viaAppWav(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, req: tts.Request) WavOutcome {
    const body = std.json.Stringify.valueAlloc(arena, .{
        .input = req.text,
        .lang = req.lang,
        .voice = req.voice,
        .model = req.model,
        .speed = req.speed,
        .response_format = "wav",
    }, .{}) catch return .no_app;
    const res = postToApp(io, gpa, arena, env, "/v1/audio/speech", body) orelse return .no_app;
    // An older GhostPen has no such endpoint: synthesize here instead.
    if (res.status == .not_found) return .no_app;
    if (res.status.class() != .success) return .{ .failed = errorMessage(arena, res.body) };
    return .{ .made = res.body };
}

/// The message of an OpenAI-style error body ({"error":{"message":...}}), else the body.
fn errorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const E = struct { @"error": struct { message: []const u8 = "" } = .{} };
    const e = std.json.parseFromSliceLeaky(E, arena, body, .{ .ignore_unknown_fields = true }) catch return body;
    return if (e.@"error".message.len > 0) e.@"error".message else body;
}
