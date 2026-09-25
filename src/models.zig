//! Whisper models: one resident model shared by captions and dictation (the
//! Tauri app's ModelPool), stored where GhostPen always kept them
//! (`<data dir>/GhostPen/models/ggml-<id>.bin`, so existing downloads are
//! reused), downloaded from Hugging Face on request.

const std = @import("std");
const oriel = @import("oriel");
const whisper = oriel.whisper;

const log = std.log.scoped(.models);

pub const sample_rate = whisper.sample_rate;

var mutex: std.Io.Mutex = .init;
var loaded_name: ?[]u8 = null;
var loaded: ?whisper.Context = null;
var gpu: ?[:0]const u8 = null;

/// Load the GPU backend (libggml-cuda.so next to the executable) once.
pub fn init(io: std.Io) void {
    whisper.silenceLogs();
    if (oriel.ggml_gpu.load(io) > 0) gpu = oriel.ggml_gpu.gpuName();
    log.info("whisper backend: {s}", .{gpu orelse "CPU"});
}

/// `[A-Za-z0-9._-]` only (the id becomes a file name and a URL path).
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return !std.mem.eql(u8, id, ".") and !std.mem.eql(u8, id, "..");
}

/// `<data dir>/GhostPen/models` (created). Caller frees.
pub fn dir(gpa: std.mem.Allocator) ![]u8 {
    const base = try oriel.store.dataDir(gpa, "GhostPen");
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "models" });
}

/// The model file's path. Caller frees.
pub fn path(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    if (!validId(id)) return error.InvalidModel;
    const d = try dir(gpa);
    defer gpa.free(d);
    const name = try std.fmt.allocPrint(gpa, "ggml-{s}.bin", .{id});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ d, name });
}

pub fn isDownloaded(io: std.Io, gpa: std.mem.Allocator, id: []const u8) bool {
    const p = path(gpa, id) catch return false;
    defer gpa.free(p);
    std.Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

/// Load `id` unless it's already the resident model. Caller holds `mutex`.
fn ensureLocked(gpa: std.mem.Allocator, id: []const u8) !whisper.Context {
    if (loaded) |ctx| if (loaded_name) |n| if (std.mem.eql(u8, n, id)) return ctx;
    const p = try path(gpa, id);
    defer gpa.free(p);
    const pz = try gpa.dupeZ(u8, p);
    defer gpa.free(pz);
    const ctx = whisper.loadModel(pz, whisper.contextDefaultParams()) catch return error.ModelLoadFailed;
    errdefer ctx.deinit();
    const name = try gpa.dupe(u8, id);
    // Swap: one model resident at a time (GPU memory).
    if (loaded) |old| old.deinit();
    if (loaded_name) |old| gpa.free(old);
    loaded = ctx;
    loaded_name = name;
    log.info("loaded whisper model {s}", .{id});
    return ctx;
}

/// Load `id` now (so a session starts without the load delay).
pub fn ensure(io: std.Io, gpa: std.mem.Allocator, id: []const u8) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = try ensureLocked(gpa, id);
}

/// Transcribe mono 16 kHz samples with model `id`. Caller frees the text.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, id: []const u8, samples: []const f32, language: []const u8, translate: bool) ![]u8 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const ctx = try ensureLocked(gpa, id);
    const lang = try gpa.dupeZ(u8, if (language.len == 0) "auto" else language);
    defer gpa.free(lang);
    const threads: c_int = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
    return ctx.transcribe(gpa, samples, .{ .language = lang, .translate = translate, .threads = threads });
}

/// One download at a time (two would write the same `.part` file).
var downloading: std.atomic.Value(bool) = .init(false);

/// Download `ggml-<id>.bin` from Hugging Face into the models directory
/// (to `.part`, renamed when complete). `message` explains a failure.
pub fn download(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, id: []const u8, message: *[]const u8) !void {
    if (!validId(id)) {
        message.* = "Invalid model name.";
        return error.DownloadFailed;
    }
    if (downloading.swap(true, .acq_rel)) {
        message.* = "A model download is already running.";
        return error.DownloadFailed;
    }
    defer downloading.store(false, .release);

    const final = try path(gpa, id);
    defer gpa.free(final);
    const d = try dir(gpa);
    defer gpa.free(d);
    try std.Io.Dir.cwd().createDirPath(io, d);
    const part = try std.fmt.allocPrint(gpa, "{s}.part", .{final});
    defer gpa.free(part);
    const url = try std.fmt.allocPrint(arena, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{s}.bin", .{id});

    fetchTo(io, gpa, arena, url, part, id, message) catch |err| {
        // Closed by fetchTo already (Windows can't delete an open file).
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        return err;
    };
    try std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), final, io);
    log.info("downloaded whisper model {s}", .{id});
}

/// GET `url` into the file `dest`; the file is closed on return.
fn fetchTo(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, dest: []const u8, id: []const u8, message: *[]const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, dest, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &fw.interface }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "Download failed ({s}).", .{@errorName(err)});
        return error.DownloadFailed;
    };
    if (res.status != .ok) {
        message.* = try std.fmt.allocPrint(arena, "Download failed: HTTP {d} for model \"{s}\".", .{ @intFromEnum(res.status), id });
        return error.DownloadFailed;
    }
    try fw.interface.flush();
}

/// Test hook: when set (from $GHOSTPEN_TEST_AUDIO, a 16 kHz mono PCM16 WAV),
/// captions and dictation stream these samples instead of the sound server,
/// so tests never capture the user's real audio.
pub var test_audio: ?[]const f32 = null;

/// Stream `test_audio` in real time (100 ms chunks, then silence) to `sink`
/// while `running` is set.
pub fn feedTestAudio(io: std.Io, running: *std.atomic.Value(bool), ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const f32) void) void {
    const samples = test_audio orelse return;
    const chunk = sample_rate / 10;
    const silence = [_]f32{0} ** (sample_rate / 10);
    var pos: usize = 0;
    while (running.load(.acquire)) {
        io.sleep(.fromMilliseconds(100), .awake) catch return;
        const end = @min(pos + chunk, samples.len);
        sink(ctx, if (pos < samples.len) samples[pos..end] else &silence);
        pos = end;
    }
}

/// 16 kHz mono PCM16 WAV → samples. Caller frees.
pub fn decodeWav(gpa: std.mem.Allocator, data: []const u8) ![]f32 {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;
    var pos: usize = 12;
    var fmt_ok = false;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        const body_end = std.math.add(usize, body_start, size) catch return error.BadWav;
        if (body_end > data.len) return error.BadWav;
        const body = data[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.BadWav;
            const format = std.mem.readInt(u16, body[0..2], .little);
            const channels = std.mem.readInt(u16, body[2..4], .little);
            const sr = std.mem.readInt(u32, body[4..8], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            if (format != 1 or channels != 1 or sr != sample_rate or bits != 16) return error.UnsupportedWav;
            fmt_ok = true;
        } else if (std.mem.eql(u8, id, "data")) {
            if (!fmt_ok) return error.BadWav;
            const out = try gpa.alloc(f32, body.len / 2);
            for (out, 0..) |*o, i| o.* = @as(f32, @floatFromInt(std.mem.readInt(i16, body[i * 2 ..][0..2], .little))) / 32768.0;
            return out;
        }
        pos = body_end + (size & 1);
    }
    return error.BadWav;
}

/// Strip whisper's bracketed sound tags ("[MUSIC]", "[BLANK_AUDIO]") and
/// collapse whitespace. Result points into `arena`.
pub fn cleanTranscript(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var pending_space = false;
    for (text) |c| {
        switch (c) {
            '[' => depth += 1,
            ']' => depth -|= 1,
            else => if (depth == 0) {
                if (std.ascii.isWhitespace(c)) {
                    pending_space = out.items.len > 0;
                } else {
                    if (pending_space) try out.append(arena, ' ');
                    pending_space = false;
                    try out.append(arena, c);
                }
            },
        }
    }
    return out.items;
}

/// Mic level 0..1 for the dictation waveform: sqrt of the RMS, ×2.2.
pub fn level(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var sum: f32 = 0;
    for (samples) |s| sum += s * s;
    const rms = @sqrt(sum / @as(f32, @floatFromInt(samples.len)));
    return std.math.clamp(@sqrt(rms) * 2.2, 0, 1);
}

test cleanTranscript {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try cleanTranscript(a, "[KNOCKING ON DOOR]"));
    try std.testing.expectEqualStrings("hello world", try cleanTranscript(a, "hello [MUSIC] world"));
    try std.testing.expectEqualStrings("plain words", try cleanTranscript(a, "  plain words  "));
}

test validId {
    try std.testing.expect(validId("base.en"));
    try std.testing.expect(!validId("../x"));
    try std.testing.expect(!validId(""));
}

test level {
    try std.testing.expectEqual(@as(f32, 0), level(&.{}));
    try std.testing.expect(level(&([_]f32{0.5} ** 16)) > 0.9);
}
