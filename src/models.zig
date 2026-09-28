//! Whisper models: one resident model shared by captions and dictation (the
//! Tauri app's ModelPool), stored where GhostPen always kept them
//! (`<data dir>/GhostPen/models/ggml-<id>.bin`, so existing downloads are
//! reused), downloaded from Hugging Face on request.

const std = @import("std");
const oriel = @import("oriel");
const whisper = oriel.whisper;
const builtin = @import("builtin");
const llm_models = @import("llm_models.zig");
const whisper_helper = @import("whisper_helper.zig");

const log = std.log.scoped(.models);

pub const sample_rate = whisper.sample_rate;

/// Serializes the runner's use: one request at a time, and no start or stop
/// in between.
var mutex: std.Io.Mutex = .init;

/// The executable started as the runner (`--whisper-helper`); set at startup.
pub var helper_exe: ?[]const u8 = null;
/// Stop the runner (freeing the GPU backend and the model) after this long
/// without a request. Captions keep it busy every few seconds.
pub var idle_minutes: u32 = 5;

pub const Entry = struct {
    id: []const u8,
    size: u64,
    sha256: []const u8,
    /// Relative 1-5 scores for the UI.
    speed: u8,
    accuracy: u8,
    note: []const u8,
};

/// `ggml-<id>.bin` in ggerganov/whisper.cpp, fastest first. Sizes and
/// hashes from Hugging Face's API (2026-09).
pub const catalog = [_]Entry{
    .{ .id = "tiny", .size = 77691713, .sha256 = "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", .speed = 5, .accuracy = 1, .note = "fastest, lowest accuracy" },
    .{ .id = "tiny.en", .size = 77704715, .sha256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f", .speed = 5, .accuracy = 1, .note = "fastest, English only" },
    .{ .id = "base", .size = 147951465, .sha256 = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", .speed = 5, .accuracy = 2, .note = "fast, basic accuracy" },
    .{ .id = "base.en", .size = 147964211, .sha256 = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", .speed = 5, .accuracy = 2, .note = "fast, English only" },
    .{ .id = "small", .size = 487601967, .sha256 = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", .speed = 4, .accuracy = 3, .note = "balanced; the live-caption sweet spot on a GPU" },
    .{ .id = "small.en", .size = 487614201, .sha256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", .speed = 4, .accuracy = 3, .note = "balanced, English only" },
    .{ .id = "medium", .size = 1533763059, .sha256 = "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", .speed = 2, .accuracy = 4, .note = "accurate, heavy" },
    .{ .id = "medium.en", .size = 1533774781, .sha256 = "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356", .speed = 2, .accuracy = 4, .note = "accurate, English only" },
    .{ .id = "large-v3-turbo-q5_0", .size = 574041195, .sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", .speed = 3, .accuracy = 5, .note = "large-model accuracy at small's size; recommended for dictation" },
    .{ .id = "large-v3-turbo-q8_0", .size = 874188075, .sha256 = "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", .speed = 3, .accuracy = 5, .note = "large turbo, 8-bit" },
    .{ .id = "large-v3-turbo", .size = 1624555275, .sha256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", .speed = 3, .accuracy = 5, .note = "large turbo, full precision" },
    .{ .id = "large-v3-q5_0", .size = 1081140203, .sha256 = "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", .speed = 1, .accuracy = 5, .note = "large v3, 5-bit; slowest" },
    .{ .id = "large-v3", .size = 3095033483, .sha256 = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", .speed = 1, .accuracy = 5, .note = "large v3, full precision; slowest, heaviest" },
};

pub fn find(id: []const u8) ?Entry {
    for (catalog) |e| if (std.mem.eql(u8, e.id, id)) return e;
    return null;
}

/// Other apps' model folders (GhostReel's; LM Studio's), searched for `ggml-<id>.bin`
/// and never written. Set once at startup.
pub var search_dirs: []const []const u8 = &.{};

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

/// The model's file: ours, else one in another app's folder. Caller frees.
pub fn resolve(io: std.Io, gpa: std.mem.Allocator, id: []const u8) !?[]u8 {
    const own = try path(gpa, id);
    if (std.Io.Dir.cwd().access(io, own, .{})) |_| return own else |_| {}
    gpa.free(own);
    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "ggml-{s}.bin", .{id}) catch return null;
    for (search_dirs) |root| {
        const p = try std.fs.path.join(gpa, &.{ root, name });
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| return p else |_| {}
        gpa.free(p);
    }
    return null;
}

pub fn isDownloaded(io: std.Io, gpa: std.mem.Allocator, id: []const u8) bool {
    const p = (resolve(io, gpa, id) catch return false) orelse return false;
    gpa.free(p);
    return true;
}

/// Load `id` now (so a session starts without the load delay), starting the
/// runner if needed.
pub fn ensure(io: std.Io, gpa: std.mem.Allocator, id: []const u8) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try resolve(io, gpa, id)) orelse return error.ModelNotFound;
    defer gpa.free(p);
    _ = try request(io, gpa, arena.allocator(), .{ .cmd = "load", .model = p }, &.{});
}

/// Oriel's voice activity detection model, written once to `<models>/vad`
/// (not next to the whisper models, which the Speech models list scans).
/// Whisper then hears only the speech: silence made it invent text and, past
/// 30 s, repeat the last sentence until the end of the recording.
var vad_path: ?[:0]u8 = null;
var vad_tried = false;

/// The VAD model's path, or null (logged once) when it can't be written:
/// transcription then runs on all of the audio. Caller holds `mutex`.
fn vadLocked(io: std.Io, gpa: std.mem.Allocator) ?[:0]const u8 {
    if (vad_tried) return vad_path;
    vad_tried = true;
    const d = dir(gpa) catch return null;
    defer gpa.free(d);
    const vad_dir = std.fs.path.join(gpa, &.{ d, "vad" }) catch return null;
    defer gpa.free(vad_dir);
    vad_path = whisper.VadModel.install(io, gpa, vad_dir) catch |err| {
        log.warn("voice activity detection unavailable ({s}): transcribing all the audio", .{@errorName(err)});
        return null;
    };
    return vad_path;
}

/// Transcribe mono 16 kHz samples with model `id`. Caller frees the text.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, id: []const u8, samples: []const f32, language: []const u8, translate: bool) ![]u8 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try resolve(io, gpa, id)) orelse return error.ModelNotFound;
    defer gpa.free(p);
    const r = try request(io, gpa, arena.allocator(), .{
        .cmd = "transcribe",
        .model = p,
        .language = if (language.len == 0) "auto" else language,
        .translate = translate,
        .vad = vadLocked(io, gpa),
    }, samples);
    return gpa.dupe(u8, r.text);
}

pub const Segment = struct {
    /// Seconds from the start of the audio.
    start: f64,
    end: f64,
    text: []const u8,
};

pub const Transcript = struct {
    segments: []const Segment,
    /// The detected (or requested) language code, e.g. "en".
    language: []const u8,

    /// The segments' text, trimmed and joined with spaces.
    pub fn text(self: Transcript, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.segments) |seg| {
            const t = std.mem.trim(u8, seg.text, " \t\r\n");
            if (t.len == 0) continue;
            if (out.items.len > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, t);
        }
        return out.items;
    }
};

/// Transcribe with segment timestamps (the STT server's verbose_json, srt
/// and vtt). Same runner and lock as `transcribe`. Results point into `arena`.
pub fn transcribeSegments(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, id: []const u8, samples: []const f32, language: []const u8) !Transcript {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const p = (try resolve(io, gpa, id)) orelse return error.ModelNotFound;
    defer gpa.free(p);
    // With VAD, whisper.cpp maps segment times back onto the original audio.
    const r = try request(io, gpa, arena, .{
        .cmd = "transcribe",
        .model = p,
        .language = if (language.len == 0) "auto" else language,
        .segments = true,
        .vad = vadLocked(io, gpa),
    }, samples);
    const segments = try arena.alloc(Segment, r.segments.len);
    for (segments, r.segments) |*out, seg| out.* = .{ .start = seg.start, .end = seg.end, .text = try cleanTranscript(arena, seg.text) };
    return .{ .segments = segments, .language = if (r.language.len > 0) r.language else try arena.dupe(u8, language) };
}

// ---- the runner (whisper_helper.zig) --------------------------------------------------

const Runner = struct {
    child: std.process.Child,
    stdout_buf: []u8,
    reader: std.Io.File.Reader,
    stdin_buf: [64 * 1024]u8 = undefined,
    stdin: std.Io.File.Writer,
    stderr_thread: ?std.Thread = null,
    cpu: bool,
    next_id: u64 = 1,
    last_used: std.Io.Clock.Timestamp,
};

/// Guarded by `mutex`.
var runner: ?*Runner = null;
var runner_gpa: std.mem.Allocator = undefined;
var busy: std.atomic.Value(bool) = .init(false);
var watchdog: ?std.Thread = null;
/// Set once the GPU failed to load a model: runners start on the CPU.
var cpu_only = false;

/// The last lines whisper.cpp wrote to stderr, for the log.
var tail_mutex: std.Io.Mutex = .init;
var tail_buf: [2048]u8 = undefined;
var tail_len: usize = 0;

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

const Reply = struct {
    id: u64 = 0,
    @"error": ?[]const u8 = null,
    text: []const u8 = "",
    language: []const u8 = "",
    segments: []const struct { start: f64 = 0, end: f64 = 0, text: []const u8 = "" } = &.{},
};

/// Send `req` (followed by `samples`) and wait for its answer, starting the
/// runner if needed. A model the GPU can't load is retried once on the CPU.
/// Caller holds `mutex`; the reply points into `arena`.
fn request(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, samples: []const f32) !Reply {
    busy.store(true, .release);
    defer busy.store(false, .release);
    return requestOnce(io, gpa, arena, req, samples) catch |err| switch (err) {
        error.ModelLoadFailed => {
            if (cpu_only) return err;
            log.warn("the GPU could not load the whisper model; running it on the CPU", .{});
            stop(io);
            cpu_only = true;
            return requestOnce(io, gpa, arena, req, samples);
        },
        else => err,
    };
}

fn requestOnce(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, req: Request, samples: []const f32) !Reply {
    if (samples.len > whisper_helper.max_samples) return error.AudioTooLong;
    const r = try ensureRunner(io, gpa, arena);
    var line = req;
    line.id = r.next_id;
    r.next_id += 1;
    line.samples = samples.len;
    const w = &r.stdin.interface;
    std.json.Stringify.value(line, .{}, w) catch return lost(io);
    w.writeByte('\n') catch return lost(io);
    w.writeAll(std.mem.sliceAsBytes(samples)) catch return lost(io);
    w.flush() catch return lost(io);

    while (true) {
        const out = (r.reader.interface.takeDelimiter('\n') catch null) orelse return lost(io);
        // alloc_always: the line is in the reader's buffer, reused by the next read.
        const reply = std.json.parseFromSliceLeaky(Reply, arena, out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        // Id 0: a request it couldn't read (it exits then).
        if (reply.id != line.id and reply.id != 0) continue;
        r.last_used = .now(io, .awake);
        if (reply.@"error") |e| {
            log.warn("whisper runner: {s}", .{e});
            if (reply.id == 0) stop(io);
            if (std.mem.startsWith(u8, e, "could not load the model")) return error.ModelLoadFailed;
            return error.TranscribeFailed;
        }
        return reply;
    }
}

/// The runner died or the pipe broke: stop it (the next request starts another).
fn lost(io: std.Io) error{TranscribeFailed} {
    var buf: [256]u8 = undefined;
    log.warn("the whisper runner stopped (crash or out of memory): {s}", .{lastError(io, &buf)});
    stop(io);
    return error.TranscribeFailed;
}

/// The last line whisper.cpp wrote to stderr, copied into `buf`.
fn lastError(io: std.Io, buf: []u8) []const u8 {
    tail_mutex.lockUncancelable(io);
    defer tail_mutex.unlock(io);
    const t = std.mem.trim(u8, tail_buf[0..tail_len], " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| t[i + 1 ..] else t;
    const n = @min(last.len, buf.len);
    @memcpy(buf[0..n], last[0..n]);
    return buf[0..n];
}

/// The runner, started (and its GPU backend loaded) if needed. Caller holds `mutex`.
fn ensureRunner(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !*Runner {
    if (runner) |r| return r;
    const exe = helper_exe orelse return error.NoRunner;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "--whisper-helper" });
    if (cpu_only) try argv.append(arena, "--cpu");
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| {
        log.warn("could not start the whisper runner: {s}", .{@errorName(err)});
        return error.NoRunner;
    };
    const r = gpa.create(Runner) catch {
        child.kill(io);
        return error.OutOfMemory;
    };
    // A reply is one line: the segments of up to three hours of speech
    // (`whisper_helper.max_samples`) fit; pages are only touched as used.
    const buf = gpa.alloc(u8, 8 * 1024 * 1024) catch {
        gpa.destroy(r);
        child.kill(io);
        return error.OutOfMemory;
    };
    r.* = .{
        .child = child,
        .stdout_buf = buf,
        .reader = undefined,
        .stdin = undefined,
        .cpu = cpu_only,
        .last_used = .now(io, .awake),
    };
    r.reader = r.child.stdout.?.readerStreaming(io, r.stdout_buf);
    r.stdin = r.child.stdin.?.writerStreaming(io, &r.stdin_buf);
    runner_gpa = gpa;
    {
        tail_mutex.lockUncancelable(io);
        defer tail_mutex.unlock(io);
        tail_len = 0;
    }
    runner = r;
    r.stderr_thread = std.Thread.spawn(.{}, drainStderr, .{ io, r.child.stderr.? }) catch {
        // Nothing would drain stderr: the runner could block on it.
        stop(io);
        return error.NoRunner;
    };

    // The ready line, once the GPU backend is loaded; anything else a GPU
    // backend prints on stdout first is skipped.
    const Ready = struct { ready: bool = false, gpu: ?[]const u8 = null };
    const ready: Ready = while (true) {
        const line = (r.reader.interface.takeDelimiter('\n') catch null) orelse {
            var why: [256]u8 = undefined;
            log.warn("the whisper runner exited at startup: {s}", .{lastError(io, &why)});
            stop(io);
            return error.NoRunner;
        };
        const parsed = std.json.parseFromSliceLeaky(Ready, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (parsed.ready) break parsed;
    };
    log.info("whisper backend: {s}", .{ready.gpu orelse "CPU"});
    if (watchdog == null) watchdog = std.Thread.spawn(.{}, idleWatch, .{io}) catch null;
    return r;
}

/// Kill the runner and free it. Caller holds `mutex`.
fn stop(io: std.Io) void {
    const r = runner orelse return;
    runner = null;
    // Kill, let the stderr drain see EOF and end, then reap (which closes the
    // pipes): never close a pipe another thread still reads.
    if (r.child.id) |id| switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
        else => std.posix.kill(id, std.posix.SIG.KILL) catch {},
    };
    if (r.stderr_thread) |t| t.join();
    r.child.kill(io);
    runner_gpa.free(r.stdout_buf);
    runner_gpa.destroy(r);
    log.info("whisper runner stopped", .{});
}

fn drainStderr(io: std.Io, file: std.Io.File) void {
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                reader.interface.toss(reader.interface.buffered().len);
                continue;
            },
            else => return,
        } orelse return;
        log.debug("whisper runner: {s}", .{line});
        tail_mutex.lockUncancelable(io);
        defer tail_mutex.unlock(io);
        const keep = @min(line.len + 1, tail_buf.len);
        if (tail_len + keep > tail_buf.len) {
            const drop = tail_len + keep - tail_buf.len;
            std.mem.copyForwards(u8, tail_buf[0 .. tail_len - drop], tail_buf[drop..tail_len]);
            tail_len -= drop;
        }
        @memcpy(tail_buf[tail_len..][0 .. keep - 1], line[line.len - (keep - 1) ..]);
        tail_buf[tail_len + keep - 1] = '\n';
        tail_len += keep;
    }
}

/// Stop the runner after `idle_minutes` without a request.
fn idleWatch(io: std.Io) void {
    while (true) {
        io.sleep(.fromSeconds(30), .awake) catch return;
        if (busy.load(.acquire) or idle_minutes == 0) continue;
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const r = runner orelse continue;
        const idle = r.last_used.durationTo(.now(io, .awake));
        if (idle.raw.toSeconds() >= @as(i64, idle_minutes) * 60) stop(io);
    }
}

pub const ModelState = struct {
    id: []const u8,
    size: u64,
    speed: u8,
    accuracy: u8,
    note: []const u8,
    /// Where it is ("" = not downloaded).
    path: []const u8 = "",
    /// Found in another app's folder (reused; not removable here).
    external: bool = false,
    /// Bytes of an interrupted download (resumable).
    partial: u64 = 0,
};

/// A `ggml-<id>.bin` on disk that isn't in the catalog.
pub const LocalFile = struct { id: []const u8, path: []const u8, size: u64, external: bool };

pub const Status = struct {
    models: []const ModelState,
    others: []const LocalFile,
};

pub fn status(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !Status {
    const own = try dir(arena);
    var list: std.ArrayList(ModelState) = .empty;
    for (catalog) |e| {
        var st: ModelState = .{ .id = e.id, .size = e.size, .speed = e.speed, .accuracy = e.accuracy, .note = e.note };
        if (try resolve(io, gpa, e.id)) |p| {
            defer gpa.free(p);
            st.path = try arena.dupe(u8, p);
            const parent = std.fs.path.dirname(p) orelse "";
            st.external = !std.mem.eql(u8, std.mem.trimEnd(u8, parent, "/\\"), std.mem.trimEnd(u8, own, "/\\"));
        } else {
            const part = try std.fmt.allocPrint(arena, "{s}{c}ggml-{s}.bin.part", .{ own, std.fs.path.sep, e.id });
            if (std.Io.Dir.cwd().statFile(io, part, .{})) |f| st.partial = f.size else |_| {}
        }
        try list.append(arena, st);
    }
    var others: std.ArrayList(LocalFile) = .empty;
    try scan(io, arena, own, false, &others);
    for (search_dirs) |root| try scan(io, arena, root, true, &others);
    return .{ .models = list.items, .others = others.items };
}

/// Whisper models in `root` that aren't catalog ones (voice-activity models
/// and other small helpers are left out).
fn scan(io: std.Io, arena: std.mem.Allocator, root: []const u8, external: bool, out: *std.ArrayList(LocalFile)) !void {
    var d = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "ggml-") or !std.mem.endsWith(u8, entry.name, ".bin")) continue;
        const id = entry.name["ggml-".len .. entry.name.len - ".bin".len];
        if (!validId(id) or find(id) != null) continue;
        // Ours wins over another app's copy.
        var seen = false;
        for (out.items) |o| seen = seen or std.mem.eql(u8, o.id, id);
        if (seen) continue;
        const st = d.statFile(io, entry.name, .{}) catch continue;
        if (st.size < 20 * 1024 * 1024) continue;
        try out.append(arena, .{
            .id = try arena.dupe(u8, id),
            .path = try std.fs.path.join(arena, &.{ root, entry.name }),
            .size = st.size,
            .external = external,
        });
    }
}

pub const Progress = llm_models.Progress;

/// Download catalog model `id` into our folder: resumable, checked against
/// its SHA-256, one download at a time (shared with the built-in models,
/// whose Pause also stops this one). `on_progress(ctx, p)` as it goes.
pub fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    id: []const u8,
    ctx: anytype,
    comptime on_progress: fn (@TypeOf(ctx), Progress) void,
    status_out: *std.http.Status,
) !void {
    const e = find(id) orelse return error.UnknownModel;
    if (try resolve(io, gpa, id)) |p| {
        gpa.free(p); // already here (ours or another app's)
        return;
    }
    const own = try dir(arena);
    const name = try std.fmt.allocPrint(arena, "ggml-{s}.bin", .{e.id});
    const url = try std.fmt.allocPrint(arena, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{s}", .{name});
    _ = try llm_models.downloadFile(io, gpa, arena, own, e.id, name, url, e.size, e.sha256, ctx, on_progress, status_out);
    log.info("downloaded whisper model {s}", .{id});
}

pub fn cancelDownload() void {
    llm_models.cancelDownload();
}

pub fn isDownloading() bool {
    return llm_models.isDownloading();
}

/// Delete model `id` (and a partial download) from our folder; unloaded
/// first when it's the resident one. Another app's copy is never touched.
pub fn remove(io: std.Io, gpa: std.mem.Allocator, id: []const u8) !void {
    if (!llm_models.beginExclusive()) return error.Busy;
    defer llm_models.endExclusive();
    const p = try path(gpa, id);
    defer gpa.free(p);
    {
        // Held through the delete: no load of this file in between. The
        // runner may have it loaded: stopping it lets the file go.
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        stop(io);
        std.Io.Dir.cwd().deleteFile(io, p) catch |err| if (err != error.FileNotFound) return err;
    }
    const part = try std.fmt.allocPrint(gpa, "{s}.part", .{p});
    defer gpa.free(part);
    std.Io.Dir.cwd().deleteFile(io, part) catch {};
    log.info("deleted whisper model {s}", .{id});
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

test "whisper catalog" {
    for (catalog) |e| {
        try std.testing.expectEqual(@as(usize, 64), e.sha256.len);
        try std.testing.expect(validId(e.id));
        try std.testing.expect(e.size > 50 * 1024 * 1024);
    }
}
