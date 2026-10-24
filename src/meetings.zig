//! Meetings (MEETINGS.md): captions in meeting mode record system audio
//! (the others) and the microphone (me) to a meeting folder; when they
//! stop, the save pipeline merges the tracks, transcribes the whole
//! recording, labels the speakers, proofreads the transcript with the
//! active profile and writes the Markdown. The Meetings window lists,
//! plays and edits them (commands below).
//!
//! Threads: each track is written by its capture thread (captions.zig);
//! the pipeline runs on one worker thread, a meeting at a time.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");
const ai = @import("ai.zig");
const wav = @import("wav.zig");
const store = @import("meeting_store.zig");
const voices = @import("voices.zig");
const speakers = @import("speakers.zig");

const App = oriel.App;
const events = main.events;
const log = std.log.scoped(.meetings);
const gpa = std.heap.smp_allocator;
const rate = models.sample_rate;

pub const Meeting = store.Meeting;

// ---- where meetings live --------------------------------------------------------------------

/// The meetings folder: the setting, else Documents/GhostPen/Meetings.
pub fn rootDir(arena: std.mem.Allocator) ![]const u8 {
    const s = try main.shared.get(main.io, arena);
    const dir = std.mem.trim(u8, s.meetings.dir, " \t");
    if (dir.len > 0) return expandHome(arena, dir);
    // Android: no home or Documents folder an app can write; the app's own data.
    if (builtin.abi.isAndroid()) return std.fs.path.join(arena, &.{ try oriel.paths.appData(arena, .{ .name = "GhostPen" }), "Meetings" });
    return std.fs.path.join(arena, &.{ try documentsDir(arena), "GhostPen", "Meetings" });
}

fn home(arena: std.mem.Allocator) ![]const u8 {
    const env = main.environ_map;
    const h = (if (builtin.os.tag == .windows) env.get("USERPROFILE") else env.get("HOME")) orelse return error.NoHomeDir;
    return arena.dupe(u8, h);
}

fn expandHome(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len >= 1 and p[0] == '~' and (p.len == 1 or p[1] == '/' or p[1] == '\\'))
        return std.fmt.allocPrint(arena, "{s}{s}", .{ try home(arena), p[1..] });
    return arena.dupe(u8, p);
}

/// The user's Documents folder: on Linux the (localized) XDG one from
/// user-dirs.dirs, e.g. ~/Documentos; else ~/Documents.
fn documentsDir(arena: std.mem.Allocator) ![]const u8 {
    const h = try home(arena);
    if (builtin.os.tag == .linux) xdg: {
        const config = if (main.environ_map.get("XDG_CONFIG_HOME")) |c| try arena.dupe(u8, c) else try std.fs.path.join(arena, &.{ h, ".config" });
        const file = try std.fs.path.join(arena, &.{ config, "user-dirs.dirs" });
        const body = std.Io.Dir.cwd().readFileAlloc(main.io, file, arena, .limited(64 * 1024)) catch break :xdg;
        if (xdgDocuments(arena, body, h) catch null) |d| return d;
    }
    return std.fs.path.join(arena, &.{ h, "Documents" });
}

/// `XDG_DOCUMENTS_DIR="$HOME/Documentos"` → "/home/me/Documentos".
fn xdgDocuments(arena: std.mem.Allocator, body: []const u8, h: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const key = "XDG_DOCUMENTS_DIR=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const v = std.mem.trim(u8, line[key.len..], "\"");
        if (std.mem.startsWith(u8, v, "$HOME")) {
            const rest = v["$HOME".len..];
            // "$HOME/" alone means "no Documents folder": the default then.
            if (std.mem.trim(u8, rest, "/").len == 0) return null;
            return try std.fmt.allocPrint(arena, "{s}{s}", .{ h, rest });
        }
        if (std.fs.path.isAbsolute(v)) return try arena.dupe(u8, v);
    }
    return null;
}

test xdgDocuments {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/Documentos", (try xdgDocuments(a, "# c\nXDG_DESKTOP_DIR=\"$HOME/Escritorio\"\nXDG_DOCUMENTS_DIR=\"$HOME/Documentos\"\n", "/home/u")).?);
    try std.testing.expect((try xdgDocuments(a, "XDG_DOCUMENTS_DIR=\"$HOME/\"\n", "/home/u")) == null);
    try std.testing.expectEqualStrings("/data/docs", (try xdgDocuments(a, "XDG_DOCUMENTS_DIR=\"/data/docs\"", "/home/u")).?);
}

// ---- the recording -------------------------------------------------------------------------

/// One track's writer, owned by its capture thread.
const Track = struct {
    writer: ?wav.Writer = null,
    failed: bool = false,

    /// Write `samples`, first padding with silence when the track fell
    /// behind the clock by over a second (it opened late, or the sound
    /// server stopped sending: a suspended output), so both tracks stay
    /// in step with each other and with the captions' times.
    fn write(t: *Track, rec: *Recording, samples: []const f32) void {
        const w = &(t.writer orelse return);
        if (t.failed) return;
        const expected = rec.elapsedFrames();
        const after = w.frames + samples.len;
        const result = blk: {
            if (expected > after + rate) w.writeSilence(expected - after) catch |err| break :blk err;
            w.write(samples) catch |err| break :blk err;
        };
        _ = result catch |err| {
            t.failed = true;
            log.err("meeting {s}: writing the recording failed ({s})", .{ rec.id, @errorName(err) });
            events.emit(.@"ghostpen://caption-error", "Recording the meeting failed (is the disk full?). Captions go on.");
        };
    }
};

pub const Recording = struct {
    id: []u8,
    root: []u8,
    start: std.Io.Clock.Timestamp,
    started_ms: i64,
    others: Track = .{},
    me: Track = .{},

    fn elapsedFrames(r: *const Recording) u64 {
        const ms = r.start.durationTo(std.Io.Clock.Timestamp.now(main.io, .awake)).raw.toMilliseconds();
        return @intCast(@divTrunc(@max(ms, 0) * rate, 1000));
    }

    pub fn elapsedSeconds(r: *const Recording) f64 {
        return @as(f64, @floatFromInt(r.elapsedFrames())) / rate;
    }

    pub fn writeOthers(r: *Recording, samples: []const f32) void {
        r.others.write(r, samples);
    }

    pub fn writeMe(r: *Recording, samples: []const f32) void {
        r.me.write(r, samples);
    }

    /// Stop recording (the capture threads have stopped): close the tracks
    /// and hand the meeting to the save pipeline, or delete it when nothing
    /// was recorded. Frees `r`.
    pub fn end(r: *Recording) void {
        active_mutex.lockUncancelable(main.io);
        const was = active == r;
        if (was) active = null;
        active_mutex.unlock(main.io);
        if (was) main.refreshTrayIcon();
        defer {
            gpa.free(r.id);
            gpa.free(r.root);
            gpa.destroy(r);
        }
        var frames: u64 = 0;
        inline for (.{ &r.others, &r.me }) |t| if (t.writer) |*w| {
            frames = @max(frames, w.frames);
            w.finish() catch |err| log.warn("meeting {s}: closing a track ({s})", .{ r.id, @errorName(err) });
            t.writer = null;
        };
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Under a second: a start that failed, or Stop right away.
        if (frames < rate) {
            store.remove(main.io, arena, r.root, r.id) catch |err| log.warn("meeting {s}: removing the empty meeting ({s})", .{ r.id, @errorName(err) });
            return;
        }
        var m = store.load(main.io, arena, r.root, r.id) catch Meeting{};
        m.durationMs = frames * 1000 / rate;
        m.state = "saving";
        store.save(main.io, arena, r.root, r.id, m) catch |err| log.warn("meeting {s}: {s}", .{ r.id, @errorName(err) });
        emitState(r.id, m.state, 0, "");
        enqueue(r.root, r.id, .all) catch |err| {
            log.err("meeting {s}: can't queue save ({s})", .{ r.id, @errorName(err) });
            m.message = "The meeting worker couldn't start. Choose Transcribe again to retry saving.";
            setState(arena, r.root, r.id, &m, "error", 0);
        };
    }
};

var active_mutex: std.Io.Mutex = .init;
var active: ?*Recording = null;

/// Stop pressed: the meeting stops counting as recording now, not when its
/// threads have finished (a transcription in flight takes seconds), so
/// the overlay's REC clock stops and its "Saving…" shows right away.
pub fn markStopped(r: *Recording) void {
    active_mutex.lockUncancelable(main.io);
    const was = active == r;
    if (was) active = null;
    active_mutex.unlock(main.io);
    if (was) {
        emitState(r.id, "saving", 0, "");
        main.refreshTrayIcon();
    }
}

/// Start a meeting: its folder, meeting.json and the tracks' files. The
/// caller (captions.zig) feeds the tracks and calls `end`.
pub fn begin(mic: bool) !*Recording {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try main.shared.get(main.io, arena);
    const root = try rootDir(arena);
    const now = store.localNow();
    const id = try store.createFolder(main.io, arena, root, now);
    errdefer store.remove(main.io, arena, root, id) catch {};

    var shown: [32]u8 = undefined;
    const started_ms = std.Io.Clock.real.now(main.io).toMilliseconds();
    var title_buf: [64]u8 = undefined;
    const m: Meeting = .{
        .title = try std.fmt.bufPrint(&title_buf, "Meeting {s}", .{try store.displayTime(&shown, now)}),
        .startedAt = started_ms,
        .startedLocal = try store.displayTime(&shown, now),
        .mic = mic,
        .language = s.captions.language,
        .model = s.captions.model,
        .state = "recording",
    };
    try store.save(main.io, arena, root, id, m);

    const r = try gpa.create(Recording);
    errdefer gpa.destroy(r);
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    const owned_root = try gpa.dupe(u8, root);
    errdefer gpa.free(owned_root);
    r.* = .{
        .id = owned_id,
        .root = owned_root,
        .start = std.Io.Clock.Timestamp.now(main.io, .awake),
        .started_ms = started_ms,
    };
    r.others.writer = try wav.Writer.create(main.io, try store.path(arena, root, id, store.others_track), rate);
    if (mic) r.me.writer = wav.Writer.create(main.io, try store.path(arena, root, id, store.me_track), rate) catch |err| blk: {
        log.warn("meeting {s}: no microphone track ({s})", .{ id, @errorName(err) });
        break :blk null;
    };
    active_mutex.lockUncancelable(main.io);
    active = r;
    active_mutex.unlock(main.io);
    main.refreshTrayIcon();
    log.info("meeting {s}: recording{s}", .{ id, if (mic) " (with the microphone)" else "" });
    return r;
}

/// The microphone could not be opened: the meeting goes on without it.
pub fn dropMic(r: *Recording) void {
    if (r.me.writer) |*w| {
        w.finish() catch {};
        r.me.writer = null;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (store.path(arena.allocator(), r.root, r.id, store.me_track)) |p| std.Io.Dir.cwd().deleteFile(main.io, p) catch {} else |_| {}
    }
}

pub const RecordingStatus = struct { id: []const u8, seconds: f64 };

pub fn recordingStatus(arena: std.mem.Allocator) !?RecordingStatus {
    active_mutex.lockUncancelable(main.io);
    defer active_mutex.unlock(main.io);
    const r = active orelse return null;
    return .{ .id = try arena.dupe(u8, r.id), .seconds = r.elapsedSeconds() };
}

/// A meeting is recording now (Stop not pressed yet).
pub fn isRecording() bool {
    active_mutex.lockUncancelable(main.io);
    defer active_mutex.unlock(main.io);
    return active != null;
}

fn isActive(id: []const u8) bool {
    active_mutex.lockUncancelable(main.io);
    defer active_mutex.unlock(main.io);
    return if (active) |r| std.mem.eql(u8, r.id, id) else false;
}

// ---- the save pipeline -----------------------------------------------------------------------

pub const Step = enum { all, transcribe, speakers, proofread, summary, ask };

/// `prompt` and `note` (the answer to replace, "" = a new one) for `.ask`.
const Job = struct {
    root: []u8,
    id: []u8,
    step: Step,
    prompt: []u8 = &.{},
    note: []u8 = &.{},
    queuedAt: std.Io.Timestamp,

    fn init(root: []const u8, id: []const u8, step: Step, prompt: []const u8, note: []const u8) !Job {
        const owned_root = try gpa.dupe(u8, root);
        errdefer gpa.free(owned_root);
        const owned_id = try gpa.dupe(u8, id);
        errdefer gpa.free(owned_id);
        const owned_prompt = try gpa.dupe(u8, prompt);
        errdefer gpa.free(owned_prompt);
        const owned_note = try gpa.dupe(u8, note);
        return .{ .root = owned_root, .id = owned_id, .step = step, .prompt = owned_prompt, .note = owned_note, .queuedAt = std.Io.Clock.awake.now(main.io) };
    }

    fn deinit(j: Job) void {
        gpa.free(j.root);
        gpa.free(j.id);
        gpa.free(j.prompt);
        gpa.free(j.note);
    }
};

var queue_mutex: std.Io.Mutex = .init;
var queue: std.ArrayList(Job) = .empty;
var worker_running = false;
/// The meeting the worker is on (guarded by `queue_mutex`).
var working_on: ?[]u8 = null;

fn enqueue(root: []const u8, id: []const u8, step: Step) !void {
    try enqueueJob(root, id, step, "", "");
}

fn enqueueJob(root: []const u8, id: []const u8, step: Step, prompt: []const u8, note: []const u8) !void {
    queue_mutex.lockUncancelable(main.io);
    defer queue_mutex.unlock(main.io);
    // The same step for the same meeting queued twice is once; questions all go.
    if (step != .ask) for (queue.items) |j| if (std.mem.eql(u8, j.id, id) and std.mem.eql(u8, j.root, root) and j.step == step) return;
    const job = try Job.init(root, id, step, prompt, note);
    errdefer job.deinit();
    try queue.append(gpa, job);
    if (worker_running) return;
    const t = std.Thread.spawn(.{}, workerMain, .{}) catch |err| {
        _ = queue.pop().?;
        log.err("meetings: no worker thread ({s})", .{@errorName(err)});
        return err;
    };
    t.detach();
    worker_running = true;
}

fn busyWith(id: []const u8) bool {
    queue_mutex.lockUncancelable(main.io);
    defer queue_mutex.unlock(main.io);
    if (working_on) |w| if (std.mem.eql(u8, w, id)) return true;
    for (queue.items) |j| if (std.mem.eql(u8, j.id, id)) return true;
    return false;
}

fn workerMain() void {
    while (true) {
        queue_mutex.lockUncancelable(main.io);
        if (queue.items.len == 0) {
            worker_running = false;
            queue_mutex.unlock(main.io);
            return;
        }
        const job = queue.orderedRemove(0);
        working_on = job.id;
        queue_mutex.unlock(main.io);

        run(job);

        queue_mutex.lockUncancelable(main.io);
        working_on = null;
        queue_mutex.unlock(main.io);
        job.deinit();
    }
}

fn emitState(id: []const u8, state: []const u8, progress: f64, message: []const u8) void {
    events.emit(.@"ghostpen://meeting", .{ .id = id, .state = state, .progress = progress, .message = message });
}

/// Save `m` with a new state and tell the windows.
fn setState(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: *Meeting, state: []const u8, progress: f64) void {
    m.state = state;
    store.save(main.io, arena, root, id, m.*) catch |err| log.warn("meeting {s}: {s}", .{ id, @errorName(err) });
    emitState(id, state, progress, m.message);
}

fn run(job: Job) void {
    const root = job.root;
    const id = job.id;
    const step = job.step;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = store.load(main.io, arena, root, id) catch |err| return log.warn("meeting {s}: {s}", .{ id, @errorName(err) });
    m.message = "";
    const began = std.Io.Clock.awake.now(main.io);
    runSteps(arena, root, id, &m, job) catch |err| {
        const msg = if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err);
        log.warn("meeting {s}: {s}", .{ id, msg });
        m.message = arena.dupe(u8, msg) catch "";
        setState(arena, root, id, &m, "error", 0);
        if (step == .all) notifyDone(id, "Meeting not fully saved", m.message);
        return;
    };
    setState(arena, root, id, &m, "ready", 1);
    // Tests (tests/e2e-meetings.sh): a question asked once the meeting is saved.
    if (step == .all) if (main.environ_map.get("GHOSTPEN_TEST_ASK")) |q| {
        enqueueJob(root, id, .ask, q, "") catch |err| log.warn("meeting {s}: can't queue question ({s})", .{ id, @errorName(err) });
    };
    if (step == .all) {
        var dur: [16]u8 = undefined;
        const body = std.fmt.allocPrint(arena, "{s} · {s}{s}{s}", .{
            if (m.title.len > 0) m.title else "Meeting",
            store.clock(&dur, @as(f64, @floatFromInt(m.durationMs)) / 1000.0),
            if (m.message.len > 0) "\n" else "",
            m.message,
        }) catch "";
        notifyDone(id, "Meeting saved", body);
    }
    log.info("meeting {s}: {s} done in {d} s", .{ id, @tagName(step), began.durationTo(std.Io.Clock.awake.now(main.io)).toSeconds() });
}

fn runSteps(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: *Meeting, job: Job) !void {
    const step = job.step;
    const s = try main.shared.get(main.io, arena);
    if (step == .ask) {
        var chat: ChatRun = .{ .arena = arena, .id = id, .prompt = job.prompt, .began = job.queuedAt };
        defer clearChatStatus();
        chat.totals.queueMs = chat.elapsed();
        chat.publish(.loading_conversation, null);
        setState(arena, root, id, m, "asking", 0);
        const answer = try askMeeting(arena, root, id, m.*, s, job.prompt, &chat);
        var stats = chat.snapshot();
        stats.elapsedMs = chat.elapsed();
        m.notes = try withNote(arena, m.notes, job.note, job.prompt, answer, stats);
        chat.publish(.complete, null);
        return;
    }
    if (step == .summary) {
        if (m.segments.len == 0) return oriel.ipc.fail("Nothing to summarize: the meeting has no transcript.", .{});
        setState(arena, root, id, m, "summarizing", 0);
        m.summary = try summarize(arena, id, m.*, s);
        return;
    }
    if (step == .all or step == .transcribe) {
        setState(arena, root, id, m, "saving", 0);
        try mergeTracks(arena, root, id, m);
    }
    if (step == .all or step == .transcribe) {
        setState(arena, root, id, m, "transcribing", 0);
        try transcribe(arena, root, id, m, s);
    }
    if (step == .all or step == .transcribe or step == .speakers) {
        setState(arena, root, id, m, "diarizing", 0);
        try labelSpeakers(arena, m);
        if (s.meetings.speakers and speakers.available and m.segments.len > 0) byVoice: {
            const model = if (s.meetings.speakerModel.len > 0) s.meetings.speakerModel else speakers.default_model;
            const Progress = struct {
                fn report(meeting_id: []const u8, p: f64) void {
                    emitState(meeting_id, "diarizing", p, "");
                }
            };
            const audio = try store.path(arena, root, id, store.audio_name);
            speakers.findSpeakers(arena, m, audio, model, s.meetings.expectedSpeakers, id, Progress.report) catch |err| {
                log.warn("meeting {s}: speakers by voice: {s}", .{ id, @errorName(err) });
                m.message = try std.fmt.allocPrint(arena, "The speakers weren't told apart by voice ({s}): run \"Find the speakers again\" later.", .{@errorName(err)});
                break :byVoice;
            };
        }
    }
    const proofread = switch (step) {
        .all => s.meetings.proofread,
        .proofread => true,
        else => false,
    };
    if (proofread and m.segments.len > 0) {
        setState(arena, root, id, m, "proofreading", 0);
        proofreadMeeting(arena, root, id, m, s) catch |err| {
            // The transcript stands: say why there is no clean text.
            const why = if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err);
            m.message = try std.fmt.allocPrint(arena, "The proofread failed ({s}): run it again from the meeting's menu.", .{why});
        };
    }
    if (step == .all and s.meetings.summary and m.segments.len > 0) {
        setState(arena, root, id, m, "summarizing", 0);
        if (summarize(arena, id, m.*, s)) |sum| m.summary = sum else |err| {
            const why = if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err);
            m.message = try std.fmt.allocPrint(arena, "The summary failed ({s}): summarize it again from the meeting's Summary tab.", .{why});
        }
    }
}

/// others.wav (+ me.wav) → audio.wav (stereo with the mic: others left,
/// me right). Tracks of a crashed recording are repaired first.
fn mergeTracks(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: *Meeting) !void {
    const cwd = std.Io.Dir.cwd();
    const others = try store.path(arena, root, id, store.others_track);
    const me = try store.path(arena, root, id, store.me_track);
    const out = try store.path(arena, root, id, store.audio_name);
    const has_others = if (cwd.access(main.io, others, .{})) true else |_| false;
    if (!has_others) {
        // Merged already (a re-run after a crash later on): nothing to do.
        cwd.access(main.io, out, .{}) catch return oriel.ipc.fail("The meeting's audio is missing.", .{});
        return;
    }
    try wav.repair(main.io, others);
    const has_me = if (cwd.access(main.io, me, .{})) true else |_| false;
    if (has_me) {
        try wav.repair(main.io, me);
        const tmp = try store.path(arena, root, id, ".audio.wav.tmp");
        try wav.mergeStereo(main.io, others, me, tmp);
        try cwd.rename(tmp, cwd, out, main.io);
        cwd.deleteFile(main.io, others) catch {};
        cwd.deleteFile(main.io, me) catch {};
    } else {
        try cwd.rename(others, cwd, out, main.io);
        m.mic = false;
    }
    const f = try cwd.openFile(main.io, out, .{});
    defer f.close(main.io);
    const i = try wav.info(main.io, f);
    m.durationMs = i.frames() * 1000 / i.rate;
}

/// Transcription windows: 5 minutes, ending in the quietest moment of
/// their last 15 s.
const window_frames = rate * 300;
const search_frames = rate * 15;

/// Whisper over the whole recording, a track at a time: segments with
/// their times, "me" for the mic's.
fn transcribe(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: *Meeting, s: main.Settings) !void {
    // The speech model of Settings → Speech, as captions and dictation.
    const model = s.captions.model;
    // Not on the device yet (a first meeting on a new phone): fetch it now,
    // with its progress on the meeting, rather than leave the recording untranscribed.
    if (!models.isDownloaded(main.io, gpa, model)) {
        log.info("meeting {s}: downloading the whisper model {s} first", .{ id, model });
        const Report = struct {
            fn on(meeting_id: []const u8, p: models.Progress) void {
                if (p.total == 0) return;
                var buf: [96]u8 = undefined;
                const note = std.fmt.bufPrint(&buf, "Downloading the speech model ({d} of {d} MB)", .{ p.done / 1_000_000, p.total / 1_000_000 }) catch "Downloading the speech model";
                emitState(meeting_id, "transcribing", 0, note);
            }
        };
        var status: std.http.Status = .ok;
        models.download(main.io, gpa, arena, model, id, Report.on, &status) catch |err| return switch (err) {
            error.Busy => oriel.ipc.fail("The speech model \"{s}\" isn't downloaded and another download is running: Redo once it's done.", .{model}),
            else => oriel.ipc.fail("Couldn't download the speech model \"{s}\" ({s}): Redo to try again.", .{ model, @errorName(err) }),
        };
    }
    const f = try std.Io.Dir.cwd().openFile(main.io, try store.path(arena, root, id, store.audio_name), .{});
    defer f.close(main.io);
    const i = try wav.info(main.io, f);
    if (i.rate != rate) return error.UnsupportedFormat;
    const total = i.frames();
    var segs: std.ArrayList(store.Segment) = .empty;
    var language: []const u8 = "";
    const channels: u16 = @min(i.channels, 2);
    for (0..channels) |ch| {
        const speaker = if (ch == 1) store.me_id else "s1";
        var at: u64 = 0;
        while (at < total) {
            const want = @min(window_frames, total - at);
            const samples = try wav.readChannel(main.io, gpa, f, i, @intCast(ch), at, want);
            defer gpa.free(samples);
            const len = if (at + want < total) store.quietCut(samples, samples.len - @min(search_frames, samples.len), rate / 10) else samples.len;
            const part = samples[0..len];
            if (!store.silent(part)) {
                var window_arena: std.heap.ArenaAllocator = .init(gpa);
                defer window_arena.deinit();
                const t = try models.transcribeSegments(main.io, gpa, window_arena.allocator(), model, part, m.language, true);
                if (language.len == 0 and t.language.len > 0) language = try arena.dupe(u8, t.language);
                const offset = @as(f64, @floatFromInt(at)) / rate;
                for (t.segments) |seg| {
                    if (std.mem.trim(u8, seg.text, " ").len == 0) continue;
                    const words = try placeWords(arena, seg, offset, part);
                    try segs.append(arena, .{
                        // Whisper's segment times run on through the silence
                        // after a sentence: the words' are what was said.
                        .start = if (words.len > 0) words[0].start else seg.start + offset,
                        .end = if (words.len > 0) words[words.len - 1].end else seg.end + offset,
                        .speaker = speaker,
                        .text = try arena.dupe(u8, std.mem.trim(u8, seg.text, " ")),
                        .words = words,
                    });
                }
            }
            at += @max(len, 1);
            const done = @as(f64, @floatFromInt(ch * total + at)) / @as(f64, @floatFromInt(channels * total));
            emitState(id, "transcribing", done, "");
        }
    }
    std.mem.sort(store.Segment, segs.items, {}, struct {
        fn before(_: void, a: store.Segment, b: store.Segment) bool {
            return a.start < b.start;
        }
    }.before);
    // Through speakers the mic hears the call: its lines echo the others'.
    const echoes = try store.dropEcho(arena, &segs, 2.0);
    if (echoes > 0) log.info("meeting {s}: {d} microphone lines were the others' audio (echo), dropped", .{ id, echoes });
    m.segments = segs.items;
    m.final = &.{};
    if (language.len > 0) m.language = language;
    m.model = model;
}

/// A segment's words in recording time, on its speech. With VAD,
/// whisper.cpp transcribes the speech with the silences cut out, then
/// stretches the times back over the whole segment, silences included: a
/// sentence said in 3 s followed by 6 s of silence came back spread over
/// 9 s. The words are put back on the segment's loud stretches (`window`
/// is the transcribed window's audio). Times outside the segment are
/// replaced by each word's share of the text.
fn placeWords(arena: std.mem.Allocator, seg: models.Segment, offset: f64, window: []const f32) ![]const store.Word {
    const placed = try placeInSegment(arena, seg);
    const span = speechSpan(window, seg.start, seg.end);
    // Stretched: a word starts inside a long silence. Else whisper's word
    // times stand; only the last word stops where the sound does.
    var stretched = false;
    for (placed) |w| stretched = stretched or span.inSilence(seg.start, w.start);
    for (placed, 0..) |*w, i| {
        if (stretched) {
            w.start = span.squeeze(seg.start, seg.end, w.start);
            w.end = span.squeeze(seg.start, seg.end, w.end);
        } else if (i == placed.len - 1) {
            w.end = @max(w.start + 0.1, @min(w.end, span.soundEnd(seg.start, w.start)));
        }
        w.start += offset;
        w.end += offset;
    }
    return placed;
}

fn placeInSegment(arena: std.mem.Allocator, seg: models.Segment) ![]store.Word {
    const out = try arena.alloc(store.Word, seg.words.len);
    var inside = true;
    for (seg.words) |w| inside = inside and w.start >= seg.start - 0.5 and w.end <= seg.end + 0.5 and w.end >= w.start;
    var chars: usize = 0;
    for (seg.words) |w| chars += w.text.len + 1;
    var at: usize = 0;
    for (out, seg.words) |*o, w| {
        const text = try arena.dupe(u8, w.text);
        if (inside) {
            o.* = .{ .start = w.start, .end = w.end, .text = text };
        } else {
            const len = seg.end - seg.start;
            const f0 = @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(@max(chars, 1)));
            at += w.text.len + 1;
            const f1 = @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(@max(chars, 1)));
            o.* = .{ .start = seg.start + f0 * len, .end = seg.start + f1 * len, .text = text };
        }
    }
    return out;
}

/// Which 50 ms frames of a segment are speech (loud enough), to map times
/// spread over the segment onto its speech only.
const SpeechSpan = struct {
    frames: [max_frames]bool = undefined,
    n: usize = 0,
    loud: usize = 0,

    const frame_s = 0.05;
    const max_frames = 2400; // 2 minutes
    /// A silence this long (frames) is a pause between sentences, not inside words.
    const long_quiet = 20;

    fn frameAt(self: *const SpeechSpan, start: f64, t: f64) usize {
        const i: usize = @intFromFloat(@max(0, (t - start) / frame_s));
        return @min(i, self.n -| 1);
    }

    /// `t` falls well inside (0.4 s or more from where the sound stopped) a
    /// quiet stretch of a second or more: a word there was stretched, not
    /// just timed a little late.
    fn inSilence(self: *const SpeechSpan, start: f64, t: f64) bool {
        if (self.n == 0 or self.loud == self.n) return false;
        const i = self.frameAt(start, t);
        if (self.frames[i]) return false;
        var a = i;
        while (a > 0 and !self.frames[a - 1]) a -= 1;
        var b = i;
        while (b + 1 < self.n and !self.frames[b + 1]) b += 1;
        return b - a + 1 >= long_quiet and i - a >= 8;
    }

    /// Where the sound that `t` is in ends; `t` itself (and a little) when
    /// the sound had already stopped (a word timed just after it).
    fn soundEnd(self: *const SpeechSpan, start: f64, t: f64) f64 {
        if (self.n == 0 or self.loud == self.n) return std.math.inf(f64);
        var i = self.frameAt(start, t);
        if (!self.frames[i]) return t + 0.3;
        while (i < self.n and self.frames[i]) i += 1;
        return start + @as(f64, @floatFromInt(i)) * frame_s;
    }

    /// `t` (seconds, in `[start, end]`) as the same share of the speech:
    /// e.g. halfway through the segment → halfway through what's said in it.
    fn squeeze(self: *const SpeechSpan, start: f64, end: f64, t: f64) f64 {
        if (self.n == 0 or self.loud == 0 or self.loud == self.n or end <= start) return t;
        const f = std.math.clamp((t - start) / (end - start), 0, 1);
        const want = f * @as(f64, @floatFromInt(self.loud));
        var seen: f64 = 0;
        for (self.frames[0..self.n], 0..) |is_loud, i| {
            if (!is_loud) continue;
            if (seen + 1 >= want) return start + (@as(f64, @floatFromInt(i)) + (want - seen)) * frame_s;
            seen += 1;
        }
        return start + @as(f64, @floatFromInt(self.n)) * frame_s;
    }
};

fn speechSpan(window: []const f32, start: f64, end: f64) SpeechSpan {
    var span: SpeechSpan = .{};
    const per: usize = @intFromFloat(SpeechSpan.frame_s * @as(f64, rate));
    const from: usize = @intFromFloat(@max(start, 0) * @as(f64, rate));
    const to: usize = @min(window.len, @as(usize, @intFromFloat(@max(end, 0) * @as(f64, rate))));
    if (to <= from) return span;
    // Loud: over a tenth of the segment's loudest frames' level (quiet
    // speech in a loud segment still counts), and over a floor for hiss.
    var peak: f32 = 0;
    var at = from;
    while (at + per <= to and span.n < SpeechSpan.max_frames) : (at += per) {
        const r = rms(window[at..][0..per]);
        peak = @max(peak, r);
        span.n += 1;
    }
    const floor = @max(0.01, peak * 0.1);
    at = from;
    for (span.frames[0..span.n]) |*f| {
        f.* = rms(window[at..][0..per]) > floor;
        at += per;
    }
    // A short burst at the very end after a silence: the next speaker
    // starting, not this segment's speech.
    var tail = span.n;
    while (tail > 0 and span.frames[tail - 1]) tail -= 1;
    if (tail < span.n and span.n - tail <= 10) {
        var quiet_before: usize = 0;
        while (tail > quiet_before and !span.frames[tail - 1 - quiet_before]) quiet_before += 1;
        if (quiet_before >= 10) @memset(span.frames[tail..span.n], false);
    }
    // Remap only across a real silence (a second or more): within ordinary
    // speech whisper's times are right, and squeezing them would distort them.
    var quiet: usize = 0;
    var longest: usize = 0;
    for (span.frames[0..span.n]) |f| {
        quiet = if (f) 0 else quiet + 1;
        longest = @max(longest, quiet);
        span.loud += @intFromBool(f);
    }
    if (longest < SpeechSpan.long_quiet) span.loud = span.n;
    return span;
}

fn rms(x: []const f32) f32 {
    var s: f32 = 0;
    for (x) |v| s += v * v;
    return @sqrt(s / @as(f32, @floatFromInt(@max(x.len, 1))));
}

test "words spread over a segment's silence go back onto its speech" {
    // 3 s of sound, then 6 s of silence; whisper spread 3 words over all 9 s.
    const samples = try std.testing.allocator.alloc(f32, 9 * rate);
    defer std.testing.allocator.free(samples);
    for (samples, 0..) |*x, i| x.* = if (i < 3 * rate) @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.3 else 0;
    const span = speechSpan(samples, 0, 9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), span.squeeze(0, 9, 0), 0.06);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), span.squeeze(0, 9, 4.5), 0.06);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), span.squeeze(0, 9, 9), 0.06);
}

/// The speakers: "me" (the mic) and the others. Until speaker recognition
/// (MEETINGS.md phase 3) the others are one speaker; names given earlier
/// are kept.
fn labelSpeakers(arena: std.mem.Allocator, m: *Meeting) !void {
    var list: std.ArrayList(store.Speaker) = .empty;
    var used_me = false;
    var used_s1 = false;
    for (m.segments) |seg| {
        used_me = used_me or std.mem.eql(u8, seg.speaker, store.me_id);
        used_s1 = used_s1 or std.mem.eql(u8, seg.speaker, "s1");
    }
    if (used_me or m.mic) try list.append(arena, .{ .id = store.me_id, .name = keptName(m.*, store.me_id) orelse "Me" });
    if (used_s1 or !m.mic) try list.append(arena, .{ .id = "s1", .name = keptName(m.*, "s1") orelse if (m.mic) "Others" else "Speaker 1" });
    m.speakers = list.items;
}

fn keptName(m: Meeting, id: []const u8) ?[]const u8 {
    for (m.speakers) |sp| if (std.mem.eql(u8, sp.id, id)) return sp.name;
    return null;
}

/// Input characters per summary request: the summary needs the context
/// more than the proofread does (it reads much more than it writes).
fn summaryBudget(s: main.Settings) usize {
    const p = s.activeProfile();
    if (!p.isLocal()) return 6000; // unknown context (Ollama's default is small)
    const ctx: usize = s.localLlm.ctxTokens;
    // ~3.5 characters a token, less the prompt and a ~700-token answer.
    return std.math.clamp((ctx -| 1500) * 3, 2000, 20_000);
}

/// Chat can read a long meeting directly when the selected local model has
/// room. The summary's 20k-character cap forced unnecessary map/reduce calls.
fn questionBudget(s: main.Settings) usize {
    if (!s.activeProfile().isLocal()) return summaryBudget(s);
    return std.math.clamp((@as(usize, s.localLlm.ctxTokens) -| 4096) * 2, 2000, 256_000);
}

test "meeting chat uses the selected local context without enlarging unknown remote contexts" {
    var s: main.Settings = .{};
    try std.testing.expectEqual(@as(usize, 6000), questionBudget(s));
    s.profiles = &.{.{ .id = "local", .name = "Local", .provider = "local", .model = "test" }};
    s.activeProfileId = "local";
    s.localLlm.ctxTokens = 131072;
    try std.testing.expect(questionBudget(s) > 200_000);
    s.localLlm.ctxTokens = 4096;
    try std.testing.expectEqual(@as(usize, 2000), questionBudget(s));
}

/// The meeting's summary (Markdown). A meeting too long for one request is
/// taken in parts: notes on each, then the summary of the notes (notes
/// that still don't fit are condensed again, a few rounds at most).
fn summarize(arena: std.mem.Allocator, id: []const u8, m: Meeting, s: main.Settings) ![]const u8 {
    const budget = summaryBudget(s);
    const parts = try store.summaryParts(arena, m, budget);
    if (parts.len == 1) return ask(arena, s, store.summary_system, parts[0]);
    // Progress: one step per part, plus the final request.
    const total: f64 = @floatFromInt(parts.len + 1);
    var notes: std.ArrayList([]const u8) = .empty;
    for (parts, 0..) |part, i| {
        const prompt = try std.fmt.allocPrint(arena, "Part {d} of {d} of the meeting:\n\n{s}", .{ i + 1, parts.len, part });
        try notes.append(arena, try ask(arena, s, store.summary_part_system, prompt));
        emitState(id, "summarizing", @as(f64, @floatFromInt(i + 1)) / total, "");
    }
    var current = notes.items;
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const groups = try store.groupNotes(arena, current, budget);
        if (groups.len == 1) return ask(arena, s, store.summary_system, try std.fmt.allocPrint(arena, "Notes on the meeting's parts, in order:\n\n{s}", .{groups[0]}));
        var next: std.ArrayList([]const u8) = .empty;
        for (groups) |g| try next.append(arena, try ask(arena, s, store.summary_part_system, g));
        current = next.items;
    }
    // Still too long after four rounds: the summary of the first group's worth.
    const groups = try store.groupNotes(arena, current, budget);
    return ask(arena, s, store.summary_system, groups[0]);
}

/// The user's question over the meeting: the answer at once when the
/// meeting fits one request, else notes on what each part has on it
/// (parts with nothing are skipped), then the answer from the notes.
const ChatRun = struct {
    arena: std.mem.Allocator,
    id: []const u8,
    prompt: []const u8,
    began: std.Io.Timestamp,
    totals: ai.telemetry.Stats = .{},
    active: ai.telemetry.Stats = .{},
    part: usize = 0,
    parts: usize = 0,

    fn elapsed(self: *ChatRun) u64 {
        return @intCast(@max(self.began.durationTo(std.Io.Clock.awake.now(main.io)).toMilliseconds(), 0));
    }

    fn snapshot(self: *ChatRun) ai.telemetry.Stats {
        var stats = ai.telemetry.combine(self.totals, self.active);
        stats.elapsedMs = self.elapsed();
        return stats;
    }

    fn observer(self: *ChatRun) ai.telemetry.Observer {
        return .{ .context = self, .callback = report };
    }

    fn report(context: *anyopaque, progress: ai.telemetry.Progress) void {
        const self: *ChatRun = @ptrCast(@alignCast(context));
        self.active = progress.stats;
        self.active.model = self.arena.dupe(u8, progress.stats.model) catch "";
        self.active.backend = self.arena.dupe(u8, progress.stats.backend) catch "";
        if (progress.stage == .complete) {
            self.totals = ai.telemetry.combine(self.totals, self.active);
            self.active = .{};
        }
        self.publish(if (progress.stage == .complete) .loading_conversation else progress.stage, progress.prefilledTokens);
    }

    fn publish(self: *ChatRun, stage: ai.telemetry.Stage, processed: ?u64) void {
        const status: ChatStatus = .{
            .id = self.id,
            .prompt = self.prompt,
            .stage = stage,
            .stats = self.snapshot(),
            .prefilledTokens = processed,
            .prefillTotalTokens = self.active.promptTokens,
            .part = self.part,
            .parts = self.parts,
        };
        chat_status_mutex.lockUncancelable(main.io);
        chat_status = status;
        chat_status_mutex.unlock(main.io);
        events.emit(.@"ghostpen://meeting-chat-progress", status);
    }
};

pub const ChatStatus = struct {
    id: []const u8,
    prompt: []const u8,
    stage: ai.telemetry.Stage,
    stats: ai.telemetry.Stats,
    prefilledTokens: ?u64 = null,
    prefillTotalTokens: ?u64 = null,
    part: usize = 0,
    parts: usize = 0,
};
var chat_status_mutex: std.Io.Mutex = .init;
var chat_status: ?ChatStatus = null;

fn clearChatStatus() void {
    chat_status_mutex.lockUncancelable(main.io);
    defer chat_status_mutex.unlock(main.io);
    chat_status = null;
}

fn askMeeting(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: Meeting, s: main.Settings, prompt: []const u8, chat: *ChatRun) ![]const u8 {
    const personal_notes = try store.loadPersonalNotes(main.io, arena, root, id);
    var budget = questionBudget(s);
    // A runner can shrink its actual context to fit memory. Tokenization also
    // varies by language/model: retry smaller groups only for context errors.
    for (0..8) |_| {
        return answerMeetingParts(arena, id, m, s, prompt, personal_notes, budget, chat) catch |err| {
            if (err != error.CommandFailed or budget <= 2000) return err;
            const why = oriel.ipc.errorText(err);
            if (!contextTooLong(why)) return err;
            budget = @max(budget / 2, 2000);
            log.info("meeting {s}: context limit reached; retrying chat with {d}-character groups", .{ id, budget });
            continue;
        };
    }
    return oriel.ipc.fail("The meeting could not fit the model's context. Raise its context size in Settings.", .{});
}

fn contextTooLong(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "context") != null and
        (std.mem.indexOf(u8, message, "too long") != null or
            std.mem.indexOf(u8, message, "context_length_exceeded") != null or
            std.mem.indexOf(u8, message, "maximum context length") != null);
}

fn answerMeetingParts(arena: std.mem.Allocator, id: []const u8, m: Meeting, s: main.Settings, prompt: []const u8, personal_notes: []const u8, budget: usize, chat: *ChatRun) ![]const u8 {
    const parts = try store.questionParts(arena, m, personal_notes, budget);
    log.info("meeting {s}: chat reads {d} source group(s), {d}-character budget", .{ id, parts.len, budget });
    if (parts.len == 0) return oriel.ipc.fail("Nothing to ask about yet. Add notes or transcribe the meeting first.", .{});
    chat.parts = if (parts.len > 1) parts.len + 1 else 1;
    chat.part = 1;
    chat.totals.conversationMs = chat.elapsed() -| chat.totals.queueMs;
    if (parts.len == 1) return answerMeeting(arena, id, m, s, prompt, parts[0], chat);
    const total: f64 = @floatFromInt(parts.len + 1);
    var notes: std.ArrayList([]const u8) = .empty;
    for (parts, 0..) |part, i| {
        chat.part = i + 1;
        const body = try std.fmt.allocPrint(arena, "Source part {d} of {d} of the meeting:\n\n{s}", .{ i + 1, parts.len, part });
        const n = try askObserved(arena, s, store.ask_part_system, try store.askPrompt(arena, m, prompt, body), chat.observer());
        if (!store.isNone(n)) try notes.append(arena, n);
        emitState(id, "asking", @as(f64, @floatFromInt(i + 1)) / total, "");
    }
    if (notes.items.len == 0) return answerMeeting(arena, id, m, s, prompt, "(No part of the meeting had anything on this request.)", chat);
    var current = notes.items;
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const groups = try store.groupNotes(arena, current, budget);
        if (groups.len == 1) break;
        var next: std.ArrayList([]const u8) = .empty;
        for (groups) |g| {
            const n = try askObserved(arena, s, store.ask_part_system, try store.askPrompt(arena, m, prompt, g), chat.observer());
            if (!store.isNone(n)) try next.append(arena, n);
        }
        current = next.items;
    }
    const groups = try store.groupNotes(arena, current, budget);
    const body = try std.fmt.allocPrint(arena, "Notes on the meeting's parts, in order:\n\n{s}", .{if (groups.len > 0) groups[0] else "(none)"});
    return answerMeeting(arena, id, m, s, prompt, body, chat);
}

fn answerMeeting(arena: std.mem.Allocator, id: []const u8, m: Meeting, s: main.Settings, prompt: []const u8, body: []const u8, chat: *ChatRun) ![]const u8 {
    chat.part = chat.parts;
    const Emit = struct {
        id: []const u8,
        prompt: []const u8,
        chat: *ChatRun,
        fn chunk(self: *@This(), text: []const u8) void {
            if (self.chat.totals.firstTokenMs == null) self.chat.totals.firstTokenMs = self.chat.elapsed();
            events.emit(.@"ghostpen://meeting-answer", .{ .id = self.id, .prompt = self.prompt, .text = text, .reset = false });
        }
    };
    var emit: Emit = .{ .id = id, .prompt = prompt, .chat = chat };
    events.emit(.@"ghostpen://meeting-answer", .{ .id = id, .prompt = prompt, .text = "", .reset = true });
    var diag: ai.Diag = .{};
    return ai.completeStream(main.io, gpa, arena, .{
        .profile = s.activeProfile(),
        .system = store.ask_system,
        .user = .{ .text = try store.askPrompt(arena, m, prompt, body) },
        .observer = chat.observer(),
    }, &emit, Emit.chunk, &diag) catch |err|
        return if (err == error.AiFailed) oriel.ipc.fail("{s}", .{diag.message}) else err;
}

/// The saved notes whose ids are in `kept` (the page's list after a
/// Delete): it only removes answers, never adds or rewrites one.
fn keptNotes(arena: std.mem.Allocator, saved: []const store.Note, kept: []const store.Note) ![]const store.Note {
    var out: std.ArrayList(store.Note) = .empty;
    for (saved) |n| {
        for (kept) |k| {
            if (std.mem.eql(u8, n.id, k.id)) {
                try out.append(arena, n);
                break;
            }
        }
    }
    return out.items;
}

/// The notes with this answer: replacing note `replace` (asked again), else
/// a new note at the end.
fn withNote(arena: std.mem.Allocator, notes: []const store.Note, replace: []const u8, prompt: []const u8, answer: []const u8, stats: ?ai.telemetry.Stats) ![]const store.Note {
    const now = std.Io.Clock.real.now(main.io).toMilliseconds();
    var out: std.ArrayList(store.Note) = .empty;
    var replaced = false;
    var max: usize = 0;
    for (notes) |n| {
        if (n.id.len > 1 and n.id[0] == 'n') max = @max(max, std.fmt.parseInt(usize, n.id[1..], 10) catch 0);
        if (replace.len > 0 and std.mem.eql(u8, n.id, replace)) {
            try out.append(arena, .{ .id = n.id, .prompt = prompt, .answer = answer, .askedAt = now, .stats = stats });
            replaced = true;
        } else try out.append(arena, n);
    }
    if (!replaced) try out.append(arena, .{ .id = try std.fmt.allocPrint(arena, "n{d}", .{max + 1}), .prompt = prompt, .answer = answer, .askedAt = now, .stats = stats });
    return out.items;
}

/// One request to the active profile; the answer trimmed, a ```markdown
/// fence the model wrapped it in taken off.
fn ask(arena: std.mem.Allocator, s: main.Settings, system: []const u8, user: []const u8) ![]const u8 {
    return askObserved(arena, s, system, user, null);
}

fn askObserved(arena: std.mem.Allocator, s: main.Settings, system: []const u8, user: []const u8, observer: ?ai.telemetry.Observer) ![]const u8 {
    var diag: ai.Diag = .{};
    const answer = ai.complete(main.io, gpa, arena, .{ .profile = s.activeProfile(), .system = system, .user = .{ .text = user }, .observer = observer }, &diag) catch |err|
        return if (err == error.AiFailed) oriel.ipc.fail("{s}", .{diag.message}) else err;
    var t = std.mem.trim(u8, answer, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[nl + 1 ..];
        if (std.mem.endsWith(u8, t, "```")) t = t[0 .. t.len - 3];
        t = std.mem.trim(u8, t, " \t\r\n");
    }
    return t;
}

/// Input characters per proofread request: what fits the model's context
/// with the answer (about as long) and the prompt.
fn batchBudget(s: main.Settings) usize {
    const p = s.activeProfile();
    if (!p.isLocal()) return 3000; // unknown context (Ollama's default is small)
    const ctx: usize = s.localLlm.ctxTokens;
    // ~3.5 characters a token, input + answer + prompt.
    return std.math.clamp((ctx -| 600) * 3 / 2, 1000, 8000);
}

fn proofreadMeeting(arena: std.mem.Allocator, root: []const u8, id: []const u8, m: *Meeting, s: main.Settings) !void {
    const ts = try store.turns(arena, m.segments, 1200);
    const budget = batchBudget(s);
    var final: std.ArrayList(store.Segment) = .empty;
    var i: usize = 0;
    var kept_raw: usize = 0;
    while (i < ts.len) {
        const b = try store.batch(arena, m.*, ts, i, budget);
        var diag: ai.Diag = .{};
        const answer = ai.complete(main.io, gpa, arena, .{
            .profile = s.activeProfile(),
            .system = store.proofread_system,
            .user = .{ .text = b.text },
        }, &diag) catch |err| return if (err == error.AiFailed) oriel.ipc.fail("{s}", .{diag.message}) else err;
        const lines = try store.parseBatch(arena, answer, b.count);
        for (lines, 0..) |line, k| {
            const t = ts[i + k];
            const text = if (line) |l| store.stripSpeaker(l, m.speakerName(t.speaker)) else blk: {
                kept_raw += 1;
                break :blk t.text;
            };
            try final.append(arena, .{ .start = t.start, .end = t.end, .speaker = t.speaker, .text = text });
        }
        i += b.count;
        emitState(id, "proofreading", @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(ts.len)), "");
    }
    m.final = final.items;
    if (kept_raw > 0) {
        log.info("meeting {s}: {d} of {d} turns kept as transcribed (the answer skipped them)", .{ id, kept_raw, ts.len });
        m.message = try std.fmt.allocPrint(arena, "{d} of {d} passages kept as transcribed: the model skipped them.", .{ kept_raw, ts.len });
    }
    if (!m.titleEdited) title: {
        var start: std.ArrayList(u8) = .empty;
        for (m.final) |f| {
            if (start.items.len > 3000) break;
            try start.print(arena, "{s}: {s}\n", .{ m.speakerName(f.speaker), f.text });
        }
        var diag: ai.Diag = .{};
        const answer = ai.complete(main.io, gpa, arena, .{
            .profile = s.activeProfile(),
            .system = store.title_system,
            .user = .{ .text = start.items },
        }, &diag) catch break :title;
        const t = try store.cleanTitle(arena, answer);
        if (t.len > 0) m.title = t;
    }
    _ = root;
}

/// After a crash: meetings left recording or half-processed are finished.
pub fn init() void {
    const t = std.Thread.spawn(.{}, resume_, .{}) catch return;
    t.detach();
}

fn resume_() void {
    main.io.sleep(.fromSeconds(3), .awake) catch return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = rootDir(arena) catch return;
    const all = store.list(main.io, arena, root) catch return;
    for (all) |sum| {
        if (std.mem.eql(u8, sum.state, "ready") or std.mem.eql(u8, sum.state, "error")) continue;
        if (isActive(sum.id)) continue;
        log.info("meeting {s}: unfinished ({s}), finishing it", .{ sum.id, sum.state });
        enqueue(root, sum.id, .all) catch |err| {
            log.err("meeting {s}: can't queue recovery ({s})", .{ sum.id, @errorName(err) });
            var m = store.load(main.io, arena, root, sum.id) catch continue;
            m.message = "The meeting worker couldn't start. Choose Transcribe again to retry saving.";
            setState(arena, root, sum.id, &m, "error", 0);
        };
    }
}

/// A desktop notification when a meeting is saved (the overlay may be
/// hidden by then), from the main thread.
fn notifyDone(id: []const u8, title: []const u8, body: []const u8) void {
    const Ctx = struct { title: [64]u8, title_len: usize, body: [256]u8, body_len: usize };
    var ctx: Ctx = .{ .title = undefined, .title_len = @min(title.len, 64), .body = undefined, .body_len = 0 };
    @memcpy(ctx.title[0..ctx.title_len], title[0..ctx.title_len]);
    // Cut on a UTF-8 boundary.
    var n = @min(body.len, ctx.body.len);
    while (n < body.len and n > 0 and (body[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(ctx.body[0..n], body[0..n]);
    ctx.body_len = n;
    const Show = struct {
        fn run(c: Ctx) void {
            oriel.notification.notify(.{ .id = "ghostpen-meeting", .title = c.title[0..c.title_len], .body = c.body[0..c.body_len] }) catch |err|
                log.warn("notification: {s}", .{@errorName(err)});
        }
    };
    App.runOnMain(ctx, Show.run);
    log.info("meeting {s}: {s}", .{ id, title });
}

// ---- the Meetings window's audio -------------------------------------------------------------

/// WebKitGTK's <audio> can't read app:// URLs: the recordings are served
/// over 127.0.0.1 (oriel.media_server, range requests) while the Meetings
/// window wants them.
var media_mutex: std.Io.Mutex = .init;
/// The HTTP media server (desktop); Android plays them through oriel.media_scheme.
const has_media = oriel.media_server.available;
var media: if (has_media) ?*oriel.media_server.Server else ?*anyopaque = null;
var media_root: []u8 = &.{};

const media_ports = [_]u16{ 8791, 8792, 8793, 8794, 8795, 8796, 8797, 8798, 8799 };

/// The base URL of the running media server (started on first use).
fn mediaBase(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
    // Android: the WebView streams them from the app's own origin (oriel.media_scheme).
    if (comptime builtin.abi.isAndroid()) {
        try oriel.media_scheme.setRoot(root, .inside_root);
        return std.mem.trimEnd(u8, oriel.media_scheme.base_url, "/");
    }
    if (!has_media) return error.Unsupported;
    media_mutex.lockUncancelable(main.io);
    defer media_mutex.unlock(main.io);
    if (media) |srv| {
        if (std.mem.eql(u8, media_root, root)) return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
        stopMediaLocked();
    }
    std.Io.Dir.cwd().createDirPath(main.io, root) catch {};
    const srv = try gpa.create(oriel.media_server.Server);
    errdefer gpa.destroy(srv);
    const owned_root = try gpa.dupe(u8, root);
    errdefer gpa.free(owned_root);
    var last: anyerror = error.AddressInUse;
    for (media_ports) |port| {
        srv.start(main.io, gpa, .{ .root_dir = owned_root, .port = port }) catch |err| {
            last = err;
            continue;
        };
        media = srv;
        media_root = owned_root;
        log.info("meetings: audio served on 127.0.0.1:{d}", .{port});
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port});
    }
    return last;
}

fn stopMediaLocked() void {
    if (!has_media) return;
    const srv = media orelse return;
    srv.stop();
    gpa.destroy(srv);
    gpa.free(media_root);
    media = null;
    media_root = &.{};
}

// ---- commands ---------------------------------------------------------------------------

fn failId() error{CommandFailed} {
    return oriel.ipc.fail("No such meeting.", .{});
}

fn loadOrFail(arena: std.mem.Allocator, root: []const u8, id: []const u8) !Meeting {
    if (!store.validId(id)) return failId();
    return store.load(main.io, arena, root, id) catch |err| switch (err) {
        error.FileNotFound => failId(),
        else => oriel.ipc.fail("Could not read the meeting ({s}).", .{@errorName(err)}),
    };
}

pub const Detail = struct {
    id: []const u8,
    meeting: Meeting,
    /// The audio's URL ("" while recording).
    audio: []const u8,
    folder: []const u8,
    busy: bool,
    personalNotes: []const u8,
};

var notes_mutex: std.Io.Mutex = .init;

pub const Commands = struct {
    pub fn meetings_chat_status(arena: std.mem.Allocator, args: struct { id: []const u8 }) !?ChatStatus {
        chat_status_mutex.lockUncancelable(main.io);
        defer chat_status_mutex.unlock(main.io);
        var status = chat_status orelse return null;
        if (!std.mem.eql(u8, status.id, args.id)) return null;
        status.id = try arena.dupe(u8, status.id);
        status.prompt = try arena.dupe(u8, status.prompt);
        status.stats.model = try arena.dupe(u8, status.stats.model);
        status.stats.backend = try arena.dupe(u8, status.stats.backend);
        return status;
    }
    pub fn meetings_recording_status(arena: std.mem.Allocator) !@import("captions.zig").MeetingCaptureStatus {
        return @import("captions.zig").meetingStatus(arena);
    }

    pub fn meetings_start_recording(arena: std.mem.Allocator) !?RecordingStatus {
        return @import("captions.zig").startMeeting(arena);
    }

    pub fn meetings_stop_recording(_: std.mem.Allocator) void {
        @import("captions.zig").stopMeeting();
    }

    pub fn open_meetings(_: std.mem.Allocator) void {
        main.showWindow("meetings", false);
    }

    pub fn meetings_list(arena: std.mem.Allocator, args: struct { query: []const u8 = "" }) ![]const store.Summary {
        const root = try rootDir(arena);
        const all = store.list(main.io, arena, root) catch |err| return oriel.ipc.fail("Could not read {s} ({s}).", .{ root, @errorName(err) });
        const q = std.mem.trim(u8, args.query, " ");
        if (q.len == 0) return all;
        var out: std.ArrayList(store.Summary) = .empty;
        for (all) |sum| {
            const m = store.load(main.io, arena, root, sum.id) catch continue;
            if (store.matches(m, q)) try out.append(arena, sum);
        }
        return out.items;
    }

    pub fn meetings_get(arena: std.mem.Allocator, args: struct { id: []const u8 }) !Detail {
        const root = try rootDir(arena);
        const m = try loadOrFail(arena, root, args.id);
        const recording = std.mem.eql(u8, m.state, "recording");
        const audio = if (recording) "" else blk: {
            const base = mediaBase(arena, root) catch |err| {
                log.warn("meetings: no media server ({s})", .{@errorName(err)});
                break :blk "";
            };
            const file = if (std.Io.Dir.cwd().access(main.io, try store.path(arena, root, args.id, store.audio_name), .{})) store.audio_name else |_| store.others_track;
            break :blk try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base, args.id, file });
        };
        return .{
            .id = args.id,
            .meeting = m,
            .audio = audio,
            .folder = try std.fs.path.join(arena, &.{ root, args.id }),
            .busy = busyWith(args.id) or isActive(args.id),
            .personalNotes = try store.loadPersonalNotes(main.io, arena, root, args.id),
        };
    }

    pub fn meetings_save_notes(arena: std.mem.Allocator, args: struct { id: []const u8, text: []const u8 }) !void {
        const root = try rootDir(arena);
        notes_mutex.lockUncancelable(main.io);
        defer notes_mutex.unlock(main.io);
        _ = try loadOrFail(arena, root, args.id);
        store.savePersonalNotes(main.io, arena, root, args.id, args.text) catch |err|
            return oriel.ipc.fail("Could not save your notes ({s}).", .{@errorName(err)});
    }

    /// The page's edits: title, speakers (names, merges), lines (text,
    /// speaker), clean text, and the answers kept (Delete on an answer).
    /// Only fields sent are changed.
    pub fn meetings_update(arena: std.mem.Allocator, args: struct {
        id: []const u8,
        title: ?[]const u8 = null,
        speakers: ?[]const store.Speaker = null,
        segments: ?[]const store.Segment = null,
        final: ?[]const store.Segment = null,
        notes: ?[]const store.Note = null,
    }) !Meeting {
        const root = try rootDir(arena);
        var m = try loadOrFail(arena, root, args.id);
        if (!m.editable() or busyWith(args.id)) return oriel.ipc.fail("Wait until the meeting is saved.", .{});
        if (args.title) |t| {
            const title = std.mem.trim(u8, t, " \t\r\n");
            if (title.len > 0) {
                m.title = title;
                m.titleEdited = true;
            }
        }
        if (args.speakers) |v| m.speakers = v;
        if (args.segments) |v| m.segments = v;
        if (args.final) |v| m.final = v;
        if (args.notes) |v| m.notes = try keptNotes(arena, m.notes, v);
        store.check(m) catch return oriel.ipc.fail("That edit doesn't fit the meeting (unknown speaker or bad times).", .{});
        store.save(main.io, arena, root, args.id, m) catch |err| return oriel.ipc.fail("Could not save the meeting ({s}).", .{@errorName(err)});
        return m;
    }

    pub fn meetings_delete(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const root = try rootDir(arena);
        if (!store.validId(args.id)) return failId();
        if (isActive(args.id)) return oriel.ipc.fail("This meeting is still recording: stop the captions first.", .{});
        if (busyWith(args.id)) return oriel.ipc.fail("Wait until the meeting is saved.", .{});
        store.remove(main.io, arena, root, args.id) catch |err| return oriel.ipc.fail("Could not delete the meeting ({s}).", .{@errorName(err)});
        log.info("meeting {s}: deleted", .{args.id});
    }

    /// Ask about the meeting: the answer is saved with it (a new note, or
    /// `note`'s answer replaced). Progress as `ghostpen://meeting` "asking".
    pub fn meetings_ask(arena: std.mem.Allocator, args: struct { id: []const u8, prompt: []const u8, note: []const u8 = "" }) !void {
        const root = try rootDir(arena);
        const m = try loadOrFail(arena, root, args.id);
        if (std.mem.eql(u8, m.state, "recording")) return oriel.ipc.fail("Wait until the meeting is saved.", .{});
        const personal_notes = try store.loadPersonalNotes(main.io, arena, root, args.id);
        if (m.segments.len == 0 and m.final.len == 0 and m.summary.len == 0 and m.notes.len == 0 and personal_notes.len == 0)
            return oriel.ipc.fail("Nothing to ask about yet. Add notes or transcribe the meeting first.", .{});
        const prompt = std.mem.trim(u8, args.prompt, " \t\r\n");
        if (prompt.len == 0) return oriel.ipc.fail("Write what you want to know.", .{});
        if (prompt.len > 4000) return oriel.ipc.fail("That request is too long.", .{});
        enqueueJob(root, args.id, .ask, prompt, args.note) catch |err| return oriel.ipc.fail("Could not queue the question ({s}). Try again.", .{@errorName(err)});
    }

    /// Run a step: "transcribe" (and everything after), "speakers",
    /// "proofread", or "summary".
    pub fn meetings_reprocess(arena: std.mem.Allocator, args: struct { id: []const u8, step: []const u8 }) !void {
        const root = try rootDir(arena);
        const m = try loadOrFail(arena, root, args.id);
        if (!m.editable() or busyWith(args.id)) return oriel.ipc.fail("Wait until the meeting is saved.", .{});
        const step = std.meta.stringToEnum(Step, args.step) orelse return oriel.ipc.fail("Unknown step.", .{});
        if (step == .ask) return oriel.ipc.fail("Ask with meetings_ask (it needs the question).", .{});
        enqueue(root, args.id, step) catch |err| return oriel.ipc.fail("Could not queue the meeting ({s}). Try again.", .{@errorName(err)});
    }

    /// The meeting as text: "transcript" or "final" (Markdown), "srt",
    /// "text" (the clean text, else the transcript, without times).
    pub fn meetings_export(arena: std.mem.Allocator, args: struct { id: []const u8, format: []const u8 }) ![]const u8 {
        const root = try rootDir(arena);
        const m = try loadOrFail(arena, root, args.id);
        const eql = std.mem.eql;
        const f = args.format;
        if (eql(u8, f, "transcript")) return store.renderTranscript(arena, m, m.segments);
        if (eql(u8, f, "final")) return store.renderTranscript(arena, m, if (m.final.len > 0) m.final else m.segments);
        if (eql(u8, f, "srt")) return store.renderSrt(arena, m, m.segments);
        if (eql(u8, f, "summary")) {
            if (m.summary.len == 0) return oriel.ipc.fail("No summary yet: summarize the meeting first.", .{});
            return std.fmt.allocPrint(arena, "# {s}\n\n{s}\n", .{ if (m.title.len > 0) m.title else "Meeting", m.summary });
        }
        if (eql(u8, f, "text")) {
            var out: std.ArrayList(u8) = .empty;
            for (try store.turns(arena, if (m.final.len > 0) m.final else m.segments, std.math.maxInt(usize))) |t|
                try out.print(arena, "{s}: {s}\n\n", .{ m.speakerName(t.speaker), t.text });
            return out.items;
        }
        return oriel.ipc.fail("Unknown format.", .{});
    }

    pub fn meetings_open_folder(arena: std.mem.Allocator, args: struct { id: []const u8 = "" }) !void {
        const root = try rootDir(arena);
        const folder = if (args.id.len == 0) root else blk: {
            if (!store.validId(args.id)) return failId();
            break :blk try std.fs.path.join(arena, &.{ root, args.id });
        };
        std.Io.Dir.cwd().createDirPath(main.io, folder) catch {};
        const uri = try fileUri(arena, folder);
        App.openExternal(uri.ptr);
    }

    /// The window closed: stop serving the recordings.
    pub fn meetings_release_audio(_: std.mem.Allocator) void {
        media_mutex.lockUncancelable(main.io);
        defer media_mutex.unlock(main.io);
        stopMediaLocked();
    }

    pub fn meetings_folder(arena: std.mem.Allocator) ![]const u8 {
        return rootDir(arena);
    }

    // ---- known voices ----

    pub const VoiceInfo = struct { name: []const u8, meetings: u32, family: []const u8 };

    pub fn meetings_voices(arena: std.mem.Allocator) ![]const VoiceInfo {
        const f = voices.load(main.io, arena, try voicesPath(arena)) catch |err| return oriel.ipc.fail("Could not read the known voices ({s}).", .{@errorName(err)});
        var out: std.ArrayList(VoiceInfo) = .empty;
        for (f.voices) |v| try out.append(arena, .{ .name = v.name, .meetings = v.meetings, .family = v.family });
        return out.items;
    }

    /// Remember a meeting's speaker as a known voice, under the speaker's
    /// name: later meetings label them by it.
    pub fn meetings_remember_voice(arena: std.mem.Allocator, args: struct { id: []const u8, speaker: []const u8 }) !Meeting {
        const root = try rootDir(arena);
        var m = try loadOrFail(arena, root, args.id);
        if (!m.editable() or busyWith(args.id)) return oriel.ipc.fail("Wait until the meeting is saved.", .{});
        const sp = for (m.speakers) |sp| {
            if (std.mem.eql(u8, sp.id, args.speaker)) break sp;
        } else return oriel.ipc.fail("No such speaker.", .{});
        if (sp.embedding.len == 0 or m.voiceFamily.len == 0) return oriel.ipc.fail("This speaker's voice wasn't analysed: run \"Find the speakers again\" first.", .{});
        const path = try voicesPath(arena);
        var f = voices.load(main.io, arena, path) catch |err| return oriel.ipc.fail("Could not read the known voices ({s}).", .{@errorName(err)});
        f.voices = try voices.remember(arena, f.voices, sp.name, m.voiceFamily, sp.embedding);
        voices.save(main.io, arena, path, f) catch |err| return oriel.ipc.fail("Could not save the voice ({s}).", .{@errorName(err)});
        const list = try arena.dupe(store.Speaker, m.speakers);
        for (list) |*x| if (std.mem.eql(u8, x.id, sp.id)) {
            x.voice = sp.name;
        };
        m.speakers = list;
        store.save(main.io, arena, root, args.id, m) catch |err| return oriel.ipc.fail("Could not save the meeting ({s}).", .{@errorName(err)});
        log.info("voice \"{s}\" remembered", .{sp.name});
        return m;
    }

    pub fn meetings_forget_voice(arena: std.mem.Allocator, args: struct { name: []const u8 }) !void {
        const path = try voicesPath(arena);
        var f = voices.load(main.io, arena, path) catch |err| return oriel.ipc.fail("Could not read the known voices ({s}).", .{@errorName(err)});
        f.voices = try voices.forget(arena, f.voices, args.name);
        voices.save(main.io, arena, path, f) catch |err| return oriel.ipc.fail("Could not save the voices ({s}).", .{@errorName(err)});
    }
};

pub fn voicesPath(arena: std.mem.Allocator) ![]const u8 {
    const base = try oriel.paths.appData(arena, .{ .name = "GhostPen" });
    return std.fs.path.join(arena, &.{ base, voices.file_name });
}

/// file:// URI of an absolute path, percent-encoding what isn't plain.
fn fileUri(arena: std.mem.Allocator, p: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    if (builtin.os.tag == .windows) try out.append(arena, '/');
    for (p) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~', '/', ':' => try out.append(arena, c),
        '\\' => try out.append(arena, '/'),
        else => try out.print(arena, "%{X:0>2}", .{c}),
    };
    return out.toOwnedSliceSentinel(arena, 0);
}

test fileUri {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    if (builtin.os.tag != .windows)
        try std.testing.expectEqualStrings("file:///home/u/Docs%20x/M%C3%A9", try fileUri(arena.allocator(), "/home/u/Docs x/Mé"));
}

test keptNotes {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = [_]store.Note{ .{ .id = "n1", .prompt = "p1", .answer = "a1" }, .{ .id = "n2", .prompt = "p2", .answer = "a2" } };
    // Delete n1; a forged n3 and a rewritten n2 change nothing else.
    const kept = try keptNotes(a, &saved, &.{ .{ .id = "n2", .prompt = "x", .answer = "forged" }, .{ .id = "n3", .prompt = "new" } });
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("a2", kept[0].answer);
}
