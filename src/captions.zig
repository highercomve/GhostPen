//! Live captions: system audio → whisper → (optional AI translation) →
//! `ghostpen://caption`, shown in a click-through overlay at the bottom of
//! the screen. Port of GhostPen's captions/mod.rs.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");
const stt_server = @import("stt_server.zig");
const meetings = @import("meetings.zig");
const dictation = @import("dictation.zig");
const store = @import("meeting_store.zig");
const voices = @import("voices.zig");
const speakers = @import("speakers.zig");

const App = oriel.App;
const events = main.events;
const audio = oriel.audio_capture;
const log = std.log.scoped(.captions);
const gpa = std.heap.smp_allocator;

const rate = models.sample_rate;
const read_chunk = rate / 10; // 100 ms reads
const max_buffer = rate * 60; // drop the oldest audio past 60 s

var mutex: std.Io.Mutex = .init;
var session: ?*Session = null;
/// AI translation on/off, flipped live from the overlay.
var translate_live: std.atomic.Value(bool) = .init(false);
/// Meeting mode (MEETINGS.md) for the next start, flipped from the overlay.
var meeting_live: std.atomic.Value(bool) = .init(false);

pub fn init() void {
    // Whisper and its GPU backend run in the runner (models.zig), started on
    // the first transcription: nothing to load here, except on macOS after
    // an update (warmUpMetal).
    if (builtin.os.tag == .macos) if (std.Thread.spawn(.{}, warmUpMetal, .{})) |t| t.detach() else |_| {};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (main.shared.get(main.io, arena.allocator())) |s| {
        translate_live.store(s.captions.aiTranslate, .release);
        meeting_live.store(s.meetings.enabled, .release);
    } else |_| {}
}

/// macOS: Metal compiles whisper's GPU code the first time a new build of
/// GhostPen uses it (~20 s). Once per version, a few seconds after startup,
/// the runner loads the captions/dictation model in the background, so the
/// first dictation after an update doesn't wait; it stops again when idle.
fn warmUpMetal() void {
    main.io.sleep(.fromSeconds(5), .awake) catch return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const version = @import("ghostpen_build").version;
    const base = oriel.paths.appData(arena, .{ .name = "GhostPen" }) catch return;
    const marker = std.fs.path.join(arena, &.{ base, "whisper-warm-version" }) catch return;
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(main.io, marker, arena, .limited(64))) |seen| {
        if (std.mem.eql(u8, std.mem.trim(u8, seen, " \t\r\n"), version)) return;
    } else |_| {}
    const s = main.shared.get(main.io, arena) catch return;
    if (!models.isDownloaded(main.io, gpa, s.captions.model)) return;
    const began = std.Io.Clock.awake.now(main.io);
    models.ensure(main.io, gpa, s.captions.model) catch |err| return log.warn("whisper warm-up: {s}", .{@errorName(err)});
    log.info("whisper warm-up for {s} took {d} ms", .{ version, began.durationTo(std.Io.Clock.awake.now(main.io)).toMilliseconds() });
    cwd.writeFile(main.io, .{ .sub_path = marker, .data = version }) catch {};
}

pub fn settingsChanged() void {
    init_translate: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const s = main.shared.get(main.io, arena.allocator()) catch break :init_translate;
        translate_live.store(s.captions.aiTranslate, .release);
        meeting_live.store(s.meetings.enabled, .release);
    }
}

pub fn isRunning() bool {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    // Keep Stop available after a capture error until teardown saves any
    // recorded audio. A failed source must not strand an owned session.
    return if (session) |s| s.mode == .captions else false;
}

const CaptureMode = enum { captions, meeting };
// Capture ownership, including startup and teardown, is guarded by mutex.
var starting: ?CaptureMode = null;
var stopping = false;
/// Bumped by every stop, even with no session yet: a start that sees it
/// change (Esc while the model loads) tears its session down.
var cancel_gen: std.atomic.Value(u64) = .init(0);

const Session = struct {
    mode: CaptureMode,
    running: std.atomic.Value(bool) = .init(true),
    /// 0 opening the audio source, 1 open, 2 failed (start() waits for it).
    opened: std.atomic.Value(u8) = .init(0),
    capture_thread: ?std.Thread = null,
    worker_thread: ?std.Thread = null,
    buf_mutex: std.Io.Mutex = .init,
    samples: std.ArrayList(f32) = .empty,
    source: ?[:0]u8 = null,
    model: []u8,
    language: []u8,
    whisper_translate: bool,
    chunk_samples: usize,
    target_lang: []u8,
    /// Meeting mode: the recording the tracks go to (ended by destroy).
    rec: ?*meetings.Recording = null,
    /// Meeting mode with the microphone: its source (null = the default
    /// input), thread and captions buffer.
    mic: bool = false,
    mic_source: ?[:0]u8 = null,
    mic_thread: ?std.Thread = null,
    mic_samples: std.ArrayList(f32) = .empty,
    /// The last system-audio captions (worker thread only): a mic caption
    /// that repeats them is the call heard through the speakers.
    recent: [3][]u8 = .{ &.{}, &.{}, &.{} },
    /// Live speaker labels (meeting mode): the speakers heard so far, the
    /// known voices, and the speaker model ("" = no live labels).
    tracker: voices.Tracker = .{ .gpa = gpa },
    known: std.heap.ArenaAllocator = .init(gpa),
    known_voices: []const voices.Voice = &.{},
    speaker_model: []u8 = &.{},

    /// All fields owned; on failure nothing leaks.
    fn create(source: [:0]const u8, c: @import("settings.zig").Captions, mode: CaptureMode) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const src = try gpa.dupeZ(u8, source);
        errdefer gpa.free(src);
        const model = try gpa.dupe(u8, c.model);
        errdefer gpa.free(model);
        const lang = try gpa.dupe(u8, c.language);
        errdefer gpa.free(lang);
        const target = try gpa.dupe(u8, c.targetLang);
        // Tauri clamps to ≥ 1 s; the buffer holds at most 60 s.
        const seconds = std.math.clamp(if (std.math.isNan(c.chunkSeconds)) 5.0 else c.chunkSeconds, 1.0, 60.0);
        s.* = .{
            .mode = mode,
            .source = src,
            .model = model,
            .language = lang,
            .whisper_translate = c.whisperTranslate,
            .chunk_samples = @intFromFloat(seconds * @as(f64, @floatFromInt(rate))),
            .target_lang = target,
        };
        return s;
    }

    /// Stop the threads and free everything (blocks while a transcription
    /// or translation in flight finishes: never call it on the UI thread).
    fn destroy(s: *Session) void {
        s.running.store(false, .release);
        if (s.capture_thread) |t| t.join();
        if (s.mic_thread) |t| t.join();
        if (s.worker_thread) |t| t.join();
        // After the threads: nothing writes the tracks any more.
        if (s.rec) |r| r.end();
        s.samples.deinit(gpa);
        s.mic_samples.deinit(gpa);
        for (s.recent) |r| gpa.free(r);
        s.tracker.deinit();
        s.known.deinit();
        gpa.free(s.speaker_model);
        if (s.mic_source) |m| gpa.free(m);
        if (s.source) |src| gpa.free(src);
        gpa.free(s.model);
        gpa.free(s.language);
        gpa.free(s.target_lang);
        gpa.destroy(s);
    }

    /// Owns the audio stream: opened, read and closed on this thread.
    fn append(s: *Session, part: []const f32) void {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        if (s.rec) |r| r.writeOthers(part);
        if (s.mode == .captions) appendTo(&s.samples, part);
    }

    fn appendMic(s: *Session, part: []const f32) void {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        if (s.rec) |r| r.writeMe(part);
        if (s.mode == .captions) appendTo(&s.mic_samples, part);
    }

    fn appendTo(list: *std.ArrayList(f32), part: []const f32) void {
        list.appendSlice(gpa, part) catch return;
        if (list.items.len > max_buffer) {
            list.replaceRangeAssumeCapacity(0, list.items.len - max_buffer, &.{});
        }
    }

    /// Meeting mode: the microphone, as "Me". A microphone that won't open
    /// leaves the meeting with system audio only.
    fn micLoop(s: *Session) void {
        var stream = audio.Stream.open(s.mic_source, "GhostPen meeting microphone", rate) catch |err| {
            log.warn("open the microphone: {s}", .{@errorName(err)});
            emitError("The microphone didn't open ({s}): recording system audio only.", .{@errorName(err)});
            s.buf_mutex.lockUncancelable(main.io);
            s.mic = false;
            if (s.rec) |r| meetings.dropMic(r);
            s.buf_mutex.unlock(main.io);
            return;
        };
        defer stream.close();
        var buf: [read_chunk]f32 = undefined;
        while (s.running.load(.acquire)) {
            stream.read(&buf) catch |err| {
                emitError("The microphone stopped ({s}).", .{@errorName(err)});
                return;
            };
            s.appendMic(&buf);
        }
    }

    fn captureLoop(s: *Session) void {
        if (models.test_audio != null) {
            s.opened.store(1, .release);
            return models.feedTestAudio(main.io, &s.running, s, append);
        }
        var stream = audio.Stream.open(s.source, if (s.mode == .meeting) "GhostPen meeting" else "GhostPen captions", rate) catch |err| {
            log.warn("open audio source: {s}", .{@errorName(err)});
            s.running.store(false, .release);
            s.opened.store(2, .release);
            return;
        };
        defer stream.close();
        s.opened.store(1, .release);
        var buf: [read_chunk]f32 = undefined;
        while (s.running.load(.acquire)) {
            stream.read(&buf) catch |err| {
                emitError("Audio capture stopped ({s}).", .{@errorName(err)});
                s.running.store(false, .release);
                return;
            };
            s.append(&buf);
        }
    }

    /// Every 200 ms: once a chunk of audio is buffered, transcribe it (and
    /// translate it when asked) and emit the caption.
    fn workerLoop(s: *Session) void {
        while (s.running.load(.acquire)) {
            main.io.sleep(.fromMilliseconds(200), .awake) catch return;
            if (s.take(&s.samples)) |chunk| {
                defer gpa.free(chunk);
                s.caption(chunk, false);
            }
            if (s.take(&s.mic_samples)) |chunk| {
                defer gpa.free(chunk);
                s.caption(chunk, true);
            }
        }
    }

    /// Transcribe a chunk (and translate it when asked); emit the caption.
    fn caption(s: *Session, chunk: []const f32, mic: bool) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        // The microphone's silence between your turns: not worth a pass.
        if (mic and store.silent(chunk)) return;
        const raw = models.transcribe(main.io, gpa, s.model, chunk, s.language, s.whisper_translate) catch |err| {
            emitError("Transcription failed ({s}).", .{@errorName(err)});
            return;
        };
        defer gpa.free(raw);
        // Silence comes back as "[BLANK_AUDIO]": never show sound tags.
        const text = models.cleanTranscript(arena.allocator(), raw) catch return;
        if (text.len == 0 or !s.running.load(.acquire)) return;
        var speaker: []const u8 = if (mic) "me" else "";
        var name: []const u8 = if (mic) "Me" else "";
        if (!mic) {
            gpa.free(s.recent[0]);
            s.recent = .{ s.recent[1], s.recent[2], gpa.dupe(u8, text) catch &.{} };
            // Meeting mode: who is it, by voice.
            if (s.speaker_model.len > 0) if (speakers.liveLabel(arena.allocator(), &s.tracker, s.speaker_model, chunk, s.known_voices)) |l| {
                speaker = std.fmt.allocPrint(arena.allocator(), "s{d}", .{l.index + 1}) catch "";
                name = l.name;
            };
        } else if (s.echoes(arena.allocator(), text)) {
            log.debug("mic caption dropped as echo: {s}", .{text});
            return;
        }

        if (translate_live.load(.acquire)) {
            if (main.translateText(arena.allocator(), text, s.target_lang)) |t| {
                events.emit(.@"ghostpen://caption", .{ .text = t, .translated = true, .speaker = speaker, .name = name });
                return;
            } else |err| log.warn("translation failed ({s}); showing the original", .{@errorName(err)});
        }
        events.emit(.@"ghostpen://caption", .{ .text = text, .translated = false, .speaker = speaker, .name = name });
    }

    fn echoes(s: *Session, arena: std.mem.Allocator, text: []const u8) bool {
        const recent = std.mem.join(arena, " ", &s.recent) catch return false;
        return store.echoScore(text, recent) >= store.echo_threshold;
    }

    /// `list`'s audio once there's a chunk's worth, else null. Caller frees.
    fn take(s: *Session, list: *std.ArrayList(f32)) ?[]f32 {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        if (list.items.len < s.chunk_samples) return null;
        const out = list.toOwnedSlice(gpa) catch return null;
        return out;
    }
};

fn emitError(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log.warn("{s}", .{msg});
    events.emit(.@"ghostpen://caption-error", msg);
}

/// The source to capture: on "Auto" the system's *current* output — whatever
/// it plays through (a Bluetooth headset pairing, a monitor going to sleep):
/// the first-monitor pick before it sat on whatever monitor happened to be
/// first on the sound server (here, a virtual loopback), so when audio moved
/// to another sink, captions captured silence ("Listening…" and nothing else).
/// Otherwise a case-insensitive substring of the configured name or
/// description. Caller frees.
fn pickSource(device: []const u8) ![:0]u8 {
    const sources = try audio.listSources(gpa);
    defer audio.freeSources(gpa, sources);
    const want = std.mem.trim(u8, device, " \t");
    const auto = want.len == 0 or std.ascii.eqlIgnoreCase(want, "auto") or std.ascii.eqlIgnoreCase(want, "default");
    if (auto) {
        switch (builtin.os.tag) {
            // The sound server resolves these to its *current* default output
            // (Linux: PulseWire's pulse server and PulseAudio ≥ 15; Windows:
            // the default render endpoint in loopback mode). The stream keeps
            // the source it opened, so switching outputs needs a new session.
            .linux => if (try defaultSinkMonitor(sources)) |name| return name,
            .windows => return gpa.dupeZ(u8, "loopback"),
            else => {}, // macOS (the audio tap, BlackHole): the first monitor source
        }
        for (sources) |src| {
            if (src.monitor) return gpa.dupeZ(u8, src.name);
        }
        return error.NoSystemAudioSource;
    }
    for (sources) |src| {
        if (containsIgnoreCase(src.name, want) or containsIgnoreCase(src.description, want)) {
            return gpa.dupeZ(u8, src.name);
        }
    }
    return error.DeviceNotFound;
}

/// The monitor of the default output source: `pactl get-default-sink`
/// (PipeWire and PulseAudio both ship it; the Tauri GhostPen resolved Auto
/// the same way) + ".monitor", the name the sound server lists the sink's
/// loopback under. null: pactl is missing, or the sink has no monitor in the
/// list. Caller frees.
fn defaultSinkMonitor(sources: []const audio.Source) !?[:0]u8 {
    const run = std.process.run(gpa, main.io, .{
        .argv = &.{ "pactl", "get-default-sink" },
    }) catch |err| {
        log.debug("default sink: pactl ({s})", .{@errorName(err)});
        return null;
    };
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const sink = std.mem.trim(u8, run.stdout, " \t\r\n");
    if (sink.len == 0 or std.ascii.eqlIgnoreCase(sink, "@DEFAULT_SINK@")) return null;
    for (sources) |src| {
        if (src.monitor and src.name.len == sink.len + ".monitor".len and
            std.mem.eql(u8, src.name[0..sink.len], sink) and std.mem.eql(u8, src.name[sink.len..], ".monitor"))
            return try gpa.dupeZ(u8, src.name);
    }
    log.debug("no monitor source for the default sink {s}", .{sink});
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn acquireStart(mode: CaptureMode) !u64 {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (starting != null or stopping or session != null)
        return oriel.ipc.fail("Audio capture is already active or finishing. Stop it before starting a new recording.", .{});
    starting = mode;
    return cancel_gen.load(.acquire);
}

fn releaseStart() void {
    mutex.lockUncancelable(main.io);
    starting = null;
    mutex.unlock(main.io);
}

fn prepareMeeting(sess: *Session, s: @import("settings.zig").Settings, arena: std.mem.Allocator) !void {
    const with_mic = s.meetings.mic and models.test_audio == null;
    const rec = meetings.begin(with_mic) catch |err| return oriel.ipc.fail("Could not create the meeting's folder ({s}).", .{@errorName(err)});
    sess.rec = rec;
    // Live labels when the speaker model is already here (never a download mid-meeting).
    if (sess.mode == .captions and speakers.available and s.meetings.speakers and s.meetings.liveSpeakers) {
        const model = if (s.meetings.speakerModel.len > 0) s.meetings.speakerModel else speakers.default_model;
        if (speakers.isDownloaded(arena, model)) {
            sess.speaker_model = try gpa.dupe(u8, model);
            const path = meetings.voicesPath(arena) catch "";
            sess.known_voices = (voices.load(main.io, sess.known.allocator(), path) catch voices.File{}).voices;
        }
    }
    if (with_mic) {
        sess.mic = true;
        sess.mic_source = dictation.pickMicrophone(s.dictation.device) catch |err| blk: {
            log.warn("meeting microphone \"{s}\": {s}", .{ s.dictation.device, @errorName(err) });
            emitError("Microphone \"{s}\" not found: recording system audio only.", .{s.dictation.device});
            meetings.dropMic(rec);
            sess.mic = false;
            break :blk null;
        };
    }
}

fn openSession(sess: *Session) !void {
    sess.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{sess});
    if (sess.mic) sess.mic_thread = try std.Thread.spawn(.{}, Session.micLoop, .{sess});
    // Fail the start (like the Tauri app) when the source doesn't open.
    var waited: u32 = 0;
    while (sess.opened.load(.acquire) == 0 and waited < 3000) : (waited += 20) {
        main.io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
    if (sess.opened.load(.acquire) != 1) return oriel.ipc.fail("Could not open the audio source \"{s}\".", .{sess.source.?});
    if (sess.mode == .captions) sess.worker_thread = try std.Thread.spawn(.{}, Session.workerLoop, .{sess});
}

/// Start a session; returns the device name (in `arena`). Slow work (device
/// list, model load, opening the source) runs without holding `mutex`.
/// error.Cancelled: a stop came meanwhile, nothing is capturing.
fn start(arena: std.mem.Allocator, mode: CaptureMode) ![]const u8 {
    const gen = try acquireStart(mode);
    defer releaseStart();

    const s = try main.shared.get(main.io, arena);
    const c = s.captions;
    if (mode == .captions and !models.isDownloaded(main.io, gpa, c.model))
        return oriel.ipc.fail("Whisper model \"{s}\" isn't downloaded yet. Download it in Settings → Captions.", .{c.model});

    const source = if (models.test_audio != null) try gpa.dupeZ(u8, "test-audio") else pickSource(c.device) catch |err| return switch (@as(anyerror, err)) {
        // anyerror: on Windows "Auto" is always the loopback, so pickSource
        // can't return NoSystemAudioSource there (v0.2.25's Windows build
        // failed on it).
        error.NoSystemAudioSource => oriel.ipc.fail("No system-audio source found (on macOS, install a loopback device such as BlackHole).", .{}),
        error.DeviceNotFound => oriel.ipc.fail("Audio device \"{s}\" not found.", .{c.device}),
        else => oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)}),
    };
    defer gpa.free(source);
    if (mode == .captions)
        models.ensure(main.io, gpa, c.model) catch |err| return oriel.ipc.fail("Could not load the whisper model \"{s}\" ({s}).", .{ c.model, @errorName(err) });

    const sess = try Session.create(source, c, mode);
    // A meeting that fails to start records under a second: destroy()
    // removes its folder again.
    errdefer sess.destroy();
    translate_live.store(c.aiTranslate, .release);
    if (mode == .meeting or meeting_live.load(.acquire)) try prepareMeeting(sess, s, arena);
    try openSession(sess);
    const result = try arena.dupe(u8, source);

    mutex.lockUncancelable(main.io);
    if (cancel_gen.load(.acquire) != gen) {
        // Stopped before it was published: the errdefer above destroys it.
        mutex.unlock(main.io);
        return error.Cancelled;
    }
    session = sess;
    mutex.unlock(main.io);
    if (mode == .captions) events.emit(.@"ghostpen://captions-started", .{});
    return result;
}

/// Stop the running session. The threads are joined off the calling thread,
/// so the UI never waits for a transcription in flight.
fn stop(mode: CaptureMode) void {
    mutex.lockUncancelable(main.io);
    if (starting == mode) _ = cancel_gen.fetchAdd(1, .acq_rel);
    const s = session orelse {
        mutex.unlock(main.io);
        return;
    };
    if ((mode == .captions and s.mode != .captions) or (mode == .meeting and s.rec == null)) {
        mutex.unlock(main.io);
        return;
    }
    _ = cancel_gen.fetchAdd(1, .acq_rel);
    session = null;
    stopping = true;
    mutex.unlock(main.io);
    s.running.store(false, .release);
    // Not recording any more for the overlay; destroy() still closes the tracks.
    if (s.rec) |r| meetings.markStopped(r);
    if (std.Thread.spawn(.{}, finishStop, .{s})) |t| t.detach() else |err| {
        log.warn("cannot spawn the stop thread ({s}): stopping on this one", .{@errorName(err)});
        finishStop(s);
    }
}

fn finishStop(s: *Session) void {
    s.destroy();
    mutex.lockUncancelable(main.io);
    stopping = false;
    mutex.unlock(main.io);
}

pub const MeetingCaptureStatus = struct {
    starting: bool,
    stopping: bool,
    captions_running: bool,
    recording: ?meetings.RecordingStatus,
};

pub fn meetingStatus(arena: std.mem.Allocator) !MeetingCaptureStatus {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    return .{
        .starting = starting == .meeting,
        .stopping = stopping,
        .captions_running = starting == .captions or (if (session) |s| s.mode == .captions else false),
        .recording = if (session != null) try meetings.recordingStatus(arena) else null,
    };
}

pub fn startMeeting(arena: std.mem.Allocator) !?meetings.RecordingStatus {
    _ = start(arena, .meeting) catch |err| return if (err == error.Cancelled) null else err;
    return meetings.recordingStatus(arena);
}

pub fn stopMeeting() void {
    stop(.meeting);
}

test "recording-only capture does not buffer audio for live transcription" {
    main.io = std.testing.io;
    const settings: @import("settings.zig").Captions = .{};
    const recorder = try Session.create("test", settings, .meeting);
    defer recorder.destroy();
    recorder.append(&.{ 0.1, 0.2, 0.3 });
    recorder.appendMic(&.{ 0.4, 0.5 });
    try std.testing.expectEqual(@as(usize, 0), recorder.samples.items.len);
    try std.testing.expectEqual(@as(usize, 0), recorder.mic_samples.items.len);
    const captions = try Session.create("test", settings, .captions);
    defer captions.destroy();
    captions.append(&.{ 0.1, 0.2, 0.3 });
    captions.appendMic(&.{ 0.4, 0.5 });
    try std.testing.expectEqual(@as(usize, 3), captions.samples.items.len);
    try std.testing.expectEqual(@as(usize, 2), captions.mic_samples.items.len);
}

test "capture startup is exclusive and cancellation respects its owner" {
    main.io = std.testing.io;
    const gen = try acquireStart(.meeting);
    defer releaseStart();
    try std.testing.expectError(error.CommandFailed, acquireStart(.captions));
    try std.testing.expectError(error.CommandFailed, acquireStart(.meeting));
    stop(.captions);
    try std.testing.expectEqual(gen, cancel_gen.load(.acquire));
    stop(.meeting);
    try std.testing.expect(cancel_gen.load(.acquire) != gen);
}

/// Show the overlay with its controls (leave ghost mode), at the bottom.
pub fn open() void {
    const w = App.ensureWindow("captions") catch |err| return log.err("captions window: {s}", .{@errorName(err)});
    w.setClickThrough(false);
    w.show();
    w.focus();
    events.emit(.@"ghostpen://captions-show", .{});
}

/// The `--captions` hotkey: stop and hide when running, else show and start.
pub fn toggle() void {
    mutex.lockUncancelable(main.io);
    const blocked = starting != null or stopping or (if (session) |s| s.mode == .meeting else false);
    mutex.unlock(main.io);
    if (blocked) return;
    if (isRunning()) {
        const t = std.Thread.spawn(.{}, stopAndHide, .{}) catch return;
        t.detach();
        return;
    }
    open();
    const t = std.Thread.spawn(.{}, startFromToggle, .{}) catch return;
    t.detach();
}

fn stopAndHide() void {
    stop(.captions);
    App.runOnMain({}, struct {
        fn hide(_: void) void {
            if (App.getWindow("captions")) |w| w.hide();
        }
    }.hide);
}

fn startFromToggle() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = start(arena.allocator(), .captions) catch |err| {
        if (err == error.Cancelled) return;
        const msg = if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err);
        events.emit(.@"ghostpen://caption-error", msg);
        return;
    };
    events.emit(.@"ghostpen://captions-show", .{});
}

const Status = struct {
    available: bool,
    running: bool,
    model_ready: bool,
    model: []const u8,
    translate: bool,
    target_lang: []const u8,
    /// Meeting mode for the next start.
    meeting: bool,
    /// The meeting being recorded, if any.
    recording: ?meetings.RecordingStatus,
};

/// An audio source for the Settings pickers: `name` is what the settings
/// store (on Windows an endpoint id, unreadable), `label` what to show.
pub const Device = struct { name: []const u8, label: []const u8, monitor: bool };

/// The audio sources, system audio included only when `monitors` is set.
pub fn listDevices(arena: std.mem.Allocator, monitors: bool) ![]const Device {
    const sources = audio.listSources(gpa) catch |err| return oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)});
    defer audio.freeSources(gpa, sources);
    var list: std.ArrayList(Device) = .empty;
    for (sources) |src| {
        if (src.monitor and !monitors) continue;
        try list.append(arena, .{
            .name = try arena.dupe(u8, src.name),
            .label = try arena.dupe(u8, if (src.description.len > 0) src.description else src.name),
            .monitor = src.monitor,
        });
    }
    return list.items;
}

pub const Commands = struct {
    pub fn open_captions(_: std.mem.Allocator) void {
        open();
    }

    pub fn captions_status(arena: std.mem.Allocator) !Status {
        const s = try main.shared.get(main.io, arena);
        return .{
            .available = true,
            .running = isRunning(),
            .model_ready = models.isDownloaded(main.io, gpa, s.captions.model),
            .model = s.captions.model,
            .translate = translate_live.load(.acquire),
            .target_lang = s.captions.targetLang,
            .meeting = meeting_live.load(.acquire),
            .recording = try meetings.recordingStatus(arena),
        };
    }

    pub fn captions_list_devices(arena: std.mem.Allocator) ![]const Device {
        return listDevices(arena, true);
    }

    /// "" when a stop came during the start (quietly not capturing).
    pub fn captions_start(arena: std.mem.Allocator) ![]const u8 {
        const device = start(arena, .captions) catch |err| return if (err == error.Cancelled) "" else err;
        App.runOnMain({}, struct {
            fn show(_: void) void {
                const w = App.ensureWindow("captions") catch |err| return log.err("captions window: {s}", .{@errorName(err)});
                w.show();
            }
        }.show);
        return device;
    }

    pub fn captions_stop(_: std.mem.Allocator) void {
        stop(.captions);
    }

    pub fn captions_set_click_through(_: std.mem.Allocator, args: struct { enable: bool }) void {
        if (App.getWindow("captions")) |w| w.setClickThrough(args.enable);
    }

    pub fn captions_set_translate(_: std.mem.Allocator, args: struct { enable: bool }) !void {
        const Edit = struct {
            enable: bool,
            pub fn apply(self: @This(), s: *main.Settings) void {
                s.captions.aiTranslate = self.enable;
            }
        };
        main.shared.update(main.io, gpa, Edit{ .enable = args.enable }) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
        translate_live.store(args.enable, .release);
    }

    /// Meeting mode for the next start (a running session keeps its mode).
    pub fn captions_set_meeting(_: std.mem.Allocator, args: struct { enable: bool }) !void {
        const Edit = struct {
            enable: bool,
            pub fn apply(self: @This(), s: *main.Settings) void {
                s.meetings.enabled = self.enable;
            }
        };
        main.shared.update(main.io, gpa, Edit{ .enable = args.enable }) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
        meeting_live.store(args.enable, .release);
    }

    pub fn captions_download_model(arena: std.mem.Allocator, args: struct { model: ?[]const u8 = null }) !void {
        const s = try main.shared.get(main.io, arena);
        const id = if (args.model) |m| (if (std.mem.trim(u8, m, " ").len > 0) m else s.captions.model) else s.captions.model;
        return whisper_download_model(arena, .{ .id = id });
    }

    // ---- speech models (Settings → Speech models) ----

    pub const WhisperStatus = struct {
        status: models.Status,
        downloading: bool,
    };

    pub fn whisper_models_status(arena: std.mem.Allocator) !WhisperStatus {
        return .{
            .status = try models.status(main.io, gpa, arena),
            .downloading = models.isDownloading(),
        };
    }

    /// Progress goes to the Settings window as `ghostpen://whisper-download`.
    pub fn whisper_download_model(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const Emit = struct {
            fn progress(_: void, p: models.Progress) void {
                events.emitTo("settings", .@"ghostpen://whisper-download", p) catch {};
            }
        };
        var status: std.http.Status = .ok;
        models.download(main.io, gpa, arena, args.id, {}, Emit.progress, &status) catch |err| {
            if (err == error.Busy) return oriel.ipc.fail("Another model is downloading.", .{});
            const message: []const u8 = switch (err) {
                error.Cancelled => "",
                error.UnknownModel => "Unknown model.",
                error.ChecksumMismatch => "The download was damaged (checksum mismatch) and was deleted: try again.",
                error.RangeIgnored => "The server can't resume this download: try again to start over.",
                error.Incomplete => "The download stopped early: try again to resume it.",
                error.Stalled => "The download stalled (no data for a minute): check the connection, then resume it.",
                error.HttpError => try std.fmt.allocPrint(arena, "Download failed: HTTP {d} {s}.", .{ @intFromEnum(status), status.phrase() orelse "" }),
                else => try std.fmt.allocPrint(arena, "Download failed ({s}).", .{@errorName(err)}),
            };
            Emit.progress({}, .{ .id = args.id, .state = if (err == error.Cancelled) "cancelled" else "error", .message = message });
            if (err == error.Cancelled) return;
            return oriel.ipc.fail("{s}", .{message});
        };
        Emit.progress({}, .{ .id = args.id, .state = "done" });
    }

    pub fn whisper_cancel_download(_: std.mem.Allocator) void {
        models.cancelDownload();
    }

    pub fn whisper_delete_model(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const s = try main.shared.get(main.io, arena);
        if (std.mem.eql(u8, s.captions.model, args.id))
            return oriel.ipc.fail("Captions and dictation use this model: pick another one first.", .{});
        if (stt_server.modelOverride()) |m| if (std.mem.eql(u8, m, args.id))
            return oriel.ipc.fail("The transcription server uses this model (GHOSTPEN_STT_MODEL).", .{});
        if (!models.validId(args.id)) return oriel.ipc.fail("Invalid model name.", .{});
        models.remove(main.io, gpa, args.id) catch |err| return if (err == error.Busy)
            oriel.ipc.fail("Wait for the download to finish (or pause it) first.", .{})
        else
            oriel.ipc.fail("Could not delete the model ({s}).", .{@errorName(err)});
    }
};
