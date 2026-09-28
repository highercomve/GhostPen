//! The whisper runner: GhostPen's own executable started as
//! `ghostpen --whisper-helper [--cpu]` by `models.zig`. A separate process so
//! the GPU backend (CUDA's runtime alone is hundreds of MB) and the model live
//! outside the app: loaded on the first transcription, not at startup, and
//! returned to the system when the runner stops after a while unused. A crash
//! or an out-of-memory in whisper.cpp can't take the app down either.
//!
//! Protocol: once the GPU backend is loaded the runner prints
//!
//!     {"ready":true,"gpu":"NVIDIA GeForce RTX 4070"}      ("gpu":null on the CPU)
//!
//! then reads requests from stdin, one at a time, each a JSON line:
//!
//!     {"id":1,"cmd":"load","model":"/…/ggml-small.bin"}
//!     {"id":2,"cmd":"transcribe","model":"/…","language":"auto","translate":false,
//!      "segments":false,"vad":"/…/ggml-silero-v6.2.0.bin","samples":96000}
//!
//! A transcribe line is followed by exactly `samples` mono 16 kHz f32 samples
//! as raw bytes (native byte order: the app and the runner are the same
//! executable on the same machine). Answers, one line each:
//!
//!     {"id":1,"loaded":true}
//!     {"id":2,"text":" Hello.","language":"en","segments":[{"start":0,"end":1.2,"text":" Hello."}]}
//!     {"id":2,"error":"…"}
//!
//! One model is resident at a time (a request for another swaps it). The
//! runner exits when stdin closes. whisper.cpp's errors go to stderr, which
//! GhostPen keeps for its error messages.

const std = @import("std");
const oriel = @import("oriel");
const whisper = oriel.whisper;

const c = whisper.c;

const Request = struct {
    id: u64 = 0,
    cmd: []const u8,
    model: []const u8 = "",
    language: []const u8 = "auto",
    translate: bool = false,
    segments: bool = false,
    vad: ?[]const u8 = null,
    samples: u64 = 0,
};

const Segment = struct { start: f64, end: f64, text: []const u8 };

/// A request line (paths and a language: small).
const max_line_bytes = 64 * 1024;
/// Three hours of audio (the transcription server takes whole recordings).
pub const max_samples: u64 = 3 * 60 * 60 * whisper.sample_rate;

var io: std.Io = undefined;
var out_buf: [16 * 1024]u8 = undefined;
var out_writer: std.Io.File.Writer = undefined;

/// One JSON line on stdout.
fn send(value: anytype) void {
    const w = &out_writer.interface;
    std.json.Stringify.value(value, .{}, w) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

fn sendError(id: u64, message: []const u8) void {
    send(.{ .id = id, .@"error" = message });
}

const Loaded = struct {
    ctx: whisper.Context,
    path: []u8,
};

pub fn main(process_io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    io = process_io;
    out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var cpu = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--cpu")) cpu = true;
    }

    whisper.silenceLogs();
    const gpus: usize = if (cpu) 0 else oriel.ggml_gpu.load(io);
    send(.{ .ready = true, .gpu = if (gpus > 0) (oriel.ggml_gpu.gpuName() orelse "GPU") else null });

    var in_buf: [max_line_bytes]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const in = &in_reader.interface;

    var loaded: ?Loaded = null;
    defer if (loaded) |l| {
        l.ctx.deinit();
        gpa.free(l.path);
    };

    while (true) {
        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Not ours: without its length the samples that may follow
                // can't be skipped, so the stream is lost.
                sendError(0, "request line too long");
                return 1;
            },
            else => return 0,
        } orelse return 0; // stdin closed: GhostPen quit or stopped the runner

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const req = std.json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch {
            sendError(0, "bad request line");
            return 1; // a transcribe's samples may follow: the stream is lost
        };

        if (std.mem.eql(u8, req.cmd, "load")) {
            _ = ensureModel(gpa, &loaded, req.model) catch |err| {
                sendError(req.id, modelError(err));
                continue;
            };
            send(.{ .id = req.id, .loaded = true });
        } else if (std.mem.eql(u8, req.cmd, "unload")) {
            if (loaded) |l| {
                l.ctx.deinit();
                gpa.free(l.path);
                loaded = null;
            }
            send(.{ .id = req.id, .unloaded = true });
        } else if (std.mem.eql(u8, req.cmd, "transcribe")) {
            if (req.samples > max_samples) {
                sendError(req.id, "audio too long");
                return 1; // the samples can't be skipped without reading them all
            }
            const samples = arena.alloc(f32, @intCast(req.samples)) catch {
                sendError(req.id, "out of memory");
                return 1;
            };
            in.readSliceAll(std.mem.sliceAsBytes(samples)) catch return 0;
            const ctx = ensureModel(gpa, &loaded, req.model) catch |err| {
                sendError(req.id, modelError(err));
                continue;
            };
            transcribe(arena, ctx, req, samples) catch |err| sendError(req.id, switch (err) {
                error.OutOfMemory => "out of memory",
                else => "transcription failed",
            });
        } else {
            sendError(req.id, "unknown command");
        }
    }
}

fn modelError(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.NoModel => "no model given",
        else => "could not load the model (a damaged file, or not enough memory)",
    };
}

/// The model at `path`, loaded (swapping out another) unless it's resident.
fn ensureModel(gpa: std.mem.Allocator, loaded: *?Loaded, path: []const u8) !whisper.Context {
    if (path.len == 0) return error.NoModel;
    if (loaded.*) |l| if (std.mem.eql(u8, l.path, path)) return l.ctx;
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    // One model at a time (GPU memory): the old one goes first.
    if (loaded.*) |l| {
        l.ctx.deinit();
        gpa.free(l.path);
        loaded.* = null;
    }
    const ctx = try whisper.loadModel(pz, whisper.contextDefaultParams());
    errdefer ctx.deinit();
    loaded.* = .{ .ctx = ctx, .path = try gpa.dupe(u8, path) };
    return ctx;
}

fn threads() c_int {
    return @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
}

fn transcribe(arena: std.mem.Allocator, ctx: whisper.Context, req: Request, samples: []const f32) !void {
    const n_samples = std.math.cast(c_int, samples.len) orelse return error.AudioTooLong;
    const lang = try arena.dupeZ(u8, if (req.language.len == 0) "auto" else req.language);
    const vad: ?[:0]const u8 = if (req.vad) |v| try arena.dupeZ(u8, v) else null;
    // With VAD, whisper.cpp maps segment times back onto the original audio.
    const p = whisper.fullParams(.{ .language = lang, .translate = req.translate, .threads = threads(), .vad_model = vad });
    if (c.whisper_full(ctx.handle, p, samples.ptr, n_samples) != 0) return error.TranscribeFailed;

    const n: usize = @intCast(@max(0, c.whisper_full_n_segments(ctx.handle)));
    var text: std.ArrayList(u8) = .empty;
    const segments = try arena.alloc(Segment, if (req.segments) n else 0);
    for (0..n) |i| {
        const idx: c_int = @intCast(i);
        const t: []const u8 = if (c.whisper_full_get_segment_text(ctx.handle, idx)) |x| std.mem.span(x) else "";
        try text.appendSlice(arena, t);
        if (req.segments) segments[i] = .{
            // whisper counts in 10 ms steps
            .start = @as(f64, @floatFromInt(c.whisper_full_get_segment_t0(ctx.handle, idx))) / 100.0,
            .end = @as(f64, @floatFromInt(c.whisper_full_get_segment_t1(ctx.handle, idx))) / 100.0,
            .text = t,
        };
    }
    const lang_id = c.whisper_full_lang_id(ctx.handle);
    const detected: []const u8 = if (lang_id >= 0) (if (c.whisper_lang_str(lang_id)) |l| std.mem.span(l) else "") else "";
    send(.{ .id = req.id, .text = text.items, .language = detected, .segments = segments });
}
