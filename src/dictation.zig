//! Voice dictation: microphone → whisper (re-transcribed as you speak) →
//! optional AI proofread → clipboard, shown in the dictation pill. The text
//! is pasted at the cursor when finished (Settings → Dictation; off: only
//! copied, to review first). Port of
//! GhostPen's dictation.rs.
//!
//! Ownership: a Session is reference-counted. `current` (the listening
//! session), `latest` (the last one started, possibly still finalizing: Esc
//! or a new start silences it) and its worker thread each hold a reference.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");
const captions = @import("captions.zig");

const App = oriel.App;
const events = main.events;
const audio = oriel.audio_capture;
const log = std.log.scoped(.dictation);
const gpa = std.heap.smp_allocator;

const rate = models.sample_rate;
const read_chunk = rate / 10;
/// A session finishes on its own after 10 minutes (memory and the final
/// pass stay bounded).
const max_samples = rate * 60 * 10;
/// Live passes re-transcribe only the newest 30 s (the final pass reads all).
const live_window = rate * 30;
/// How long a finished dictation waits for a menu action to free the clipboard.
const busy_wait_ms = 5000;

/// Guards `current` and `latest` (never held across slow work).
var mutex: std.Io.Mutex = .init;
var current: ?*Session = null;
var latest: ?*Session = null;
/// A start in progress (device pick, model load): a second toggle is ignored.
var starting: std.atomic.Value(bool) = .init(false);
/// Bumped by every stop/cancel, even with no session yet: a start that sees
/// it change (Esc while the model loads) tears its session down.
var cancel_gen: std.atomic.Value(u64) = .init(0);
/// Live values the overlay can change mid-session.
var proofread_live: std.atomic.Value(bool) = .init(true);
var language_mutex: std.Io.Mutex = .init;
var language_buf: [16]u8 = undefined;
var language_len: usize = 4;

pub fn init() void {
    @memcpy(language_buf[0..4], "auto");
    settingsChanged();
}

pub fn settingsChanged() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = main.shared.get(main.io, arena.allocator()) catch return;
    proofread_live.store(s.dictation.proofread, .release);
    setLanguage(s.dictation.language);
}

fn setLanguage(lang: []const u8) void {
    language_mutex.lockUncancelable(main.io);
    defer language_mutex.unlock(main.io);
    const l = if (lang.len == 0 or lang.len > language_buf.len) "auto" else lang;
    @memcpy(language_buf[0..l.len], l);
    language_len = l.len;
}

fn language(buf: []u8) []const u8 {
    language_mutex.lockUncancelable(main.io);
    defer language_mutex.unlock(main.io);
    @memcpy(buf[0..language_len], language_buf[0..language_len]);
    return buf[0..language_len];
}

fn update(text: []const u8, state: []const u8) void {
    events.emit(.@"ghostpen://dictation", .{ .text = text, .state = state });
}

/// An error that keeps the dictated text: the pill shows `message` and
/// offers `text` to copy.
fn updateKeep(text: []const u8, message: []const u8) void {
    events.emit(.@"ghostpen://dictation", .{ .text = text, .state = "error", .message = message });
}

const Session = struct {
    refs: std.atomic.Value(u32),
    /// Capture on; cleared by stop/cancel, or when the microphone fails.
    listening: std.atomic.Value(bool) = .init(true),
    /// Cancelled (Esc, or a newer session): the worker goes silent.
    aborted: std.atomic.Value(bool) = .init(false),
    /// Stop means finalize (transcribe → proofread → copy); false = cancel.
    finalize: std.atomic.Value(bool) = .init(true),
    /// 0 opening the microphone, 1 open, 2 failed (start() waits for it).
    opened: std.atomic.Value(u8) = .init(0),
    /// Listening stopped at `max_samples` (finalized like a stop).
    capped: std.atomic.Value(bool) = .init(false),
    buf_mutex: std.Io.Mutex = .init,
    samples: std.ArrayList(f32) = .empty,
    source: ?[:0]u8,
    model: []u8,
    capture_thread: ?std.Thread = null,
    level_thread: ?std.Thread = null,

    fn create(source: ?[:0]u8, model: []const u8) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{ .refs = .init(1), .source = source, .model = try gpa.dupe(u8, model) };
        return s;
    }

    fn retain(s: *Session) *Session {
        _ = s.refs.fetchAdd(1, .monotonic);
        return s;
    }

    fn release(s: *Session) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        s.samples.deinit(gpa);
        if (s.source) |src| gpa.free(src);
        gpa.free(s.model);
        gpa.destroy(s);
    }

    fn snapshot(s: *Session) ![]f32 {
        return s.snapshotTail(std.math.maxInt(usize));
    }

    /// The newest `max` samples (all of them when fewer). Caller frees.
    fn snapshotTail(s: *Session, max: usize) ![]f32 {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        const items = s.samples.items;
        return gpa.dupe(f32, items[items.len -| max..]);
    }

    fn len(s: *Session) usize {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        return s.samples.items.len;
    }

    /// Stops listening (the worker then finalizes) at the length cap or
    /// when the buffer can't grow.
    fn append(s: *Session, part: []const f32) void {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        if (!s.listening.load(.acquire)) return;
        const room = max_samples -| s.samples.items.len;
        s.samples.appendSlice(gpa, part[0..@min(part.len, room)]) catch {
            log.err("out of memory after {d} s of audio: finishing", .{s.samples.items.len / rate});
            s.listening.store(false, .release);
            return;
        };
        if (part.len >= room) {
            log.info("dictation reached {d} min: finishing", .{max_samples / rate / 60});
            s.capped.store(true, .release);
            s.listening.store(false, .release);
        }
    }

    /// Opens, reads and closes the microphone on this thread (WASAPI/COM
    /// needs one thread); reports the open's outcome through `opened`.
    fn captureLoop(s: *Session) void {
        if (models.test_audio != null) {
            s.opened.store(1, .release);
            return models.feedTestAudio(main.io, &s.listening, s, append);
        }
        var stream = audio.Stream.open(s.source, "GhostPen dictation", rate) catch |err| {
            log.warn("open microphone: {s}", .{@errorName(err)});
            s.listening.store(false, .release);
            s.finalize.store(false, .release);
            s.aborted.store(true, .release);
            s.opened.store(2, .release);
            return;
        };
        defer stream.close();
        s.opened.store(1, .release);
        var buf: [read_chunk]f32 = undefined;
        while (s.listening.load(.acquire)) {
            stream.read(&buf) catch |err| {
                log.warn("capture: {s}", .{@errorName(err)});
                s.listening.store(false, .release);
                return;
            };
            s.append(&buf);
        }
    }

    /// ~10 Hz level of the newest 100 ms, for the waveform.
    fn levelLoop(s: *Session) void {
        while (s.listening.load(.acquire)) {
            main.io.sleep(.fromMilliseconds(100), .awake) catch return;
            s.buf_mutex.lockUncancelable(main.io);
            const items = s.samples.items;
            const tail = items[items.len -| (rate / 10)..];
            const lvl = models.level(tail);
            s.buf_mutex.unlock(main.io);
            events.emit(.@"ghostpen://dictation-level", lvl);
        }
    }

    /// Re-transcribe the newest `live_window` while listening (each time a
    /// second of new audio arrived), then finalize or report the cancel.
    /// Holds its own reference, released at the end.
    fn workerLoop(s: *Session) void {
        defer s.release();
        var last_len: usize = 0;
        while (s.listening.load(.acquire)) {
            main.io.sleep(.fromMilliseconds(250), .awake) catch break;
            const n = s.len();
            if (n < rate or n < last_len + rate) continue;
            last_len = n;
            const samples = s.snapshotTail(live_window) catch continue;
            defer gpa.free(samples);
            var lang_buf: [16]u8 = undefined;
            const raw = models.transcribe(main.io, gpa, s.model, samples, language(&lang_buf), false) catch |err| {
                log.warn("transcription: {s}", .{@errorName(err)});
                continue;
            };
            defer gpa.free(raw);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const text = models.cleanTranscript(arena.allocator(), raw) catch continue;
            if (text.len > 0 and !s.aborted.load(.acquire)) update(text, "listening");
        }
        if (s.capture_thread) |t| t.join();
        if (s.level_thread) |t| t.join();

        if (s.aborted.load(.acquire)) return;
        if (!s.finalize.load(.acquire)) return update("", "cancelled");
        if (s.capped.load(.acquire)) update("Reached the 10-minute limit: finishing\u{2026}", "transcribing");
        s.finalizeSession();
    }

    fn finalizeSession(s: *Session) void {
        const samples = s.snapshot() catch return update("Out of memory.", "error");
        defer gpa.free(samples);
        if (samples.len < rate / 2) return update("Didn\u{2019}t catch anything \u{2014} try again.", "error");

        update("", "transcribing");
        var lang_buf: [16]u8 = undefined;
        const raw = models.transcribe(main.io, gpa, s.model, samples, language(&lang_buf), false) catch |err| {
            if (!s.aborted.load(.acquire)) {
                var buf: [128]u8 = undefined;
                update(std.fmt.bufPrint(&buf, "Transcription failed: {s}", .{@errorName(err)}) catch "Transcription failed", "error");
            }
            return;
        };
        defer gpa.free(raw);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const transcript = models.cleanTranscript(arena.allocator(), raw) catch return;
        if (s.aborted.load(.acquire)) return;
        if (transcript.len == 0) return update("Didn\u{2019}t catch anything \u{2014} try again.", "error");
        update(transcript, "transcribing");

        deliver(arena.allocator(), transcript, &s.aborted);
    }
};

/// A transcript's way out (both engines): proofread when asked, then pasted
/// where the user was, or copied; the page shows the result. `aborted`: a
/// cancel or a newer session silences it.
fn deliver(arena: std.mem.Allocator, transcript: []const u8, aborted: *const std.atomic.Value(bool)) void {
    const final = if (proofread_live.load(.acquire)) blk: {
        update(transcript, "proofreading");
        break :blk main.proofread(arena, transcript) catch |err| fallback: {
            log.warn("proofread failed ({s}); using the transcript", .{@errorName(err)});
            break :fallback transcript;
        };
    } else transcript;
    if (aborted.load(.acquire)) return;

    // Shares the menu's busy guard so clipboard writes can't interleave:
    // waits a few seconds for a menu action, else keeps the text to copy.
    var waited: u32 = 0;
    while (main.busy.swap(true, .acq_rel)) : (waited += 50) {
        if (aborted.load(.acquire)) return;
        if (waited >= busy_wait_ms) return updateKeep(final, "Another action is still running: nothing was copied.");
        main.io.sleep(.fromMilliseconds(50), .awake) catch return updateKeep(final, "Nothing was copied.");
    }
    defer main.busy.store(false, .release);
    const settings = main.shared.get(main.io, arena) catch main.Settings{};
    if (settings.dictation.paste) {
        const pasted = main.pasteFromWindow(main.windowFor("dictation"), final, settings) catch |err| {
            var buf: [128]u8 = undefined;
            return update(std.fmt.bufPrint(&buf, "Clipboard error: {s}", .{@errorName(err)}) catch "Clipboard error", "error");
        };
        // Not pasted (no synthetic input): it's on the clipboard, shown as done.
        if (!pasted) log.info("dictation: {d} chars copied (no synthetic input to paste)", .{final.len});
        return update(final, "done");
    }
    oriel.clipboard.writeText(final) catch |err| {
        var buf: [128]u8 = undefined;
        return update(std.fmt.bufPrint(&buf, "Clipboard error: {s}", .{@errorName(err)}) catch "Clipboard error", "error");
    };
    log.info("dictation: {d} chars copied", .{final.len});
    update(final, "done");
}

/// The configured microphone (substring match), else the default input.
pub fn pickMicrophone(device: []const u8) !?[:0]u8 {
    const want = std.mem.trim(u8, device, " \t");
    if (want.len == 0 or std.ascii.eqlIgnoreCase(want, "auto") or std.ascii.eqlIgnoreCase(want, "default")) return null;
    const sources = try audio.listSources(gpa);
    defer audio.freeSources(gpa, sources);
    for (sources) |src| {
        if (src.monitor) continue;
        if (std.ascii.indexOfIgnoreCase(src.name, want) != null or std.ascii.indexOfIgnoreCase(src.description, want) != null)
            return try gpa.dupeZ(u8, src.name);
    }
    return error.DeviceNotFound;
}

// ---- Android's recognizer (oriel.dictation's `.system` engine) ---------------------------

/// The phone's own speech recognition (Google's on-device model on most
/// phones): nothing to download. "auto" uses it on Android when it's there.
/// Its text reaches the page as oriel.dictation's "dictation:partial" and
/// "dictation:final"; stop hands the whole of it to `deliver`.
const has_system = builtin.abi.isAndroid() and oriel.dictation.available;
var system_on: std.atomic.Value(bool) = .init(false);
var system_aborted: std.atomic.Value(bool) = .init(false);
var system_ready = false;

fn wantsSystem(engine: []const u8) bool {
    return has_system and !std.mem.eql(u8, engine, "whisper");
}

fn startSystem() !void {
    if (comptime !has_system) return error.EngineUnavailable;
    if (!system_ready) {
        const base = try oriel.paths.appData(gpa, .{ .name = "GhostPen" });
        defer gpa.free(base);
        const dir = try std.fs.path.join(gpa, &.{ base, "dictation" });
        defer gpa.free(dir);
        oriel.dictation.init(main.io, gpa, dir);
        system_ready = true;
    }
    var lang_buf: [16]u8 = undefined;
    _ = try oriel.dictation.start(.{ .engine = .system, .language = language(&lang_buf) });
    system_aborted.store(false, .release);
    system_on.store(true, .release);
    update("", "listening");
}

/// Stop the system recognizer (a worker: it waits for the last phrase), then
/// deliver what it heard, or drop it when cancelled.
fn finishSystem(finalize: bool) void {
    if (comptime !has_system) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = oriel.dictation.stop(arena.allocator()) catch |err| {
        var buf: [128]u8 = undefined;
        return update(std.fmt.bufPrint(&buf, "Speech recognition failed: {s}", .{@errorName(err)}) catch "Speech recognition failed", "error");
    };
    if (!finalize or system_aborted.load(.acquire)) return update("", "cancelled");
    const text = std.mem.trim(u8, r.text, " \t\r\n");
    if (text.len == 0) return update("Didn\u{2019}t catch anything \u{2014} try again.", "error");
    update(text, "transcribing");
    deliver(arena.allocator(), text, &system_aborted);
}

pub fn isRunning() bool {
    if (system_on.load(.acquire)) return true;
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    return if (current) |s| s.listening.load(.acquire) else false;
}

/// Start listening; returns the device name (in `arena`). Slow work (device
/// list, model load, opening the microphone) runs without holding `mutex`.
/// error.Cancelled: a stop/cancel came meanwhile, nothing is listening.
fn start(arena: std.mem.Allocator) ![]const u8 {
    if (isRunning()) return oriel.ipc.fail("Dictation is already running.", .{});
    if (starting.swap(true, .acq_rel)) return oriel.ipc.fail("Dictation is already starting.", .{});
    defer starting.store(false, .release);
    const gen = cancel_gen.load(.acquire);
    if (models.test_audio == null) try main.ensureMicrophone();

    const s = try main.shared.get(main.io, arena);
    if (wantsSystem(s.dictation.engine)) {
        if (startSystem()) {
            proofread_live.store(s.dictation.proofread, .release);
            return arena.dupe(u8, "speech recognition");
        } else |err| {
            if (std.mem.eql(u8, s.dictation.engine, "system"))
                return oriel.ipc.fail("This device's speech recognition isn't available ({s}). Pick Whisper in Settings → Speech.", .{@errorName(err)});
            log.info("dictation: the system recognizer isn't available ({s}); whisper", .{@errorName(err)});
        }
    }
    const model = s.captions.model;
    if (!models.isDownloaded(main.io, gpa, model))
        return oriel.ipc.fail("Whisper model \"{s}\" isn't downloaded yet. Download it in Settings \u{2192} Captions.", .{model});
    const source = if (models.test_audio != null) null else pickMicrophone(s.dictation.device) catch |err| return switch (err) {
        error.DeviceNotFound => oriel.ipc.fail("Microphone \"{s}\" not found.", .{s.dictation.device}),
        else => oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)}),
    };
    const device = try arena.dupe(u8, if (source) |src| src else "default");
    const sess = Session.create(source, model) catch |err| {
        if (source) |src| gpa.free(src);
        return err;
    };
    defer sess.release(); // start()'s own reference
    models.ensure(main.io, gpa, model) catch |err| return oriel.ipc.fail("Could not load the whisper model \"{s}\" ({s}).", .{ model, @errorName(err) });
    proofread_live.store(s.dictation.proofread, .release);
    setLanguage(s.dictation.language);

    // Threads: capture and level (joined by the worker), then the worker.
    sess.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{sess});
    sess.level_thread = std.Thread.spawn(.{}, Session.levelLoop, .{sess}) catch |err| {
        sess.listening.store(false, .release);
        sess.capture_thread.?.join();
        return err;
    };
    const worker = std.Thread.spawn(.{}, Session.workerLoop, .{sess.retain()}) catch |err| {
        sess.listening.store(false, .release);
        sess.capture_thread.?.join();
        sess.level_thread.?.join();
        sess.release(); // the worker's reference
        return err;
    };
    worker.detach();

    // Fail the start (like the Tauri app) when the microphone doesn't open.
    var waited: u32 = 0;
    while (sess.opened.load(.acquire) == 0 and waited < 3000) : (waited += 20) {
        main.io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
    if (sess.opened.load(.acquire) == 2) return oriel.ipc.fail("Could not open the microphone.", .{});

    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (cancel_gen.load(.acquire) != gen) {
        // Stopped before it was listening: the worker joins the threads and
        // goes silent; start()'s reference goes with the defer above.
        sess.finalize.store(false, .release);
        sess.aborted.store(true, .release);
        sess.listening.store(false, .release);
        return error.Cancelled;
    }
    // A previous session still finalizing: the user moved on, silence it.
    if (latest) |old| {
        old.aborted.store(true, .release);
        old.release();
    }
    if (current) |old| old.release();
    latest = sess.retain();
    current = sess.retain();
    return device;
}

/// Stop listening: finalize (`finalize` true) or cancel. Cancel also
/// silences a session that is still finalizing (Esc during "Polishing…").
fn end(finalize: bool) void {
    if (system_on.swap(false, .acq_rel)) {
        if (!finalize) system_aborted.store(true, .release);
        const t = std.Thread.spawn(.{}, finishSystem, .{finalize}) catch return update("", "cancelled");
        t.detach();
        return;
    }
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    _ = cancel_gen.fetchAdd(1, .acq_rel);
    if (!finalize) if (latest) |s| {
        s.finalize.store(false, .release);
        s.aborted.store(true, .release);
    };
    const s = current orelse return;
    current = null;
    s.listening.store(false, .release);
    s.release();
}

fn showOverlay() void {
    // Single-window mode without the floating panel: the app's Dictation page.
    if (!std.mem.eql(u8, main.windowFor("dictation"), "dictation")) {
        main.showWindow("dictation", false);
        return events.emit(.@"ghostpen://dictation-show", .{});
    }
    const w = App.ensureWindow("dictation") catch |err| return log.err("dictation window: {s}", .{@errorName(err)});
    w.show();
    w.focus();
    events.emit(.@"ghostpen://dictation-show", .{});
}

/// The `--voice-input` hotkey / tray item: finish when listening, else show
/// the pill and start. Ignored while a start is still in progress.
pub fn toggle() void {
    if (isRunning()) return end(true);
    if (starting.load(.acquire)) return;
    showOverlay();
    const t = std.Thread.spawn(.{}, startFromToggle, .{}) catch return;
    t.detach();
}

fn startFromToggle() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = start(arena.allocator()) catch |err| switch (err) {
        error.Cancelled => update("", "cancelled"),
        else => update(if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err), "error"),
    };
}

const Status = struct { model_ready: bool, model: []const u8, proofread: bool, language: []const u8 };

pub const Commands = struct {
    pub fn dictation_list_devices(arena: std.mem.Allocator) ![]const captions.Device {
        return captions.listDevices(arena, false);
    }

    pub fn dictation_status(arena: std.mem.Allocator) !Status {
        const s = try main.shared.get(main.io, arena);
        var lang_buf: [16]u8 = undefined;
        return .{
            .model_ready = models.isDownloaded(main.io, gpa, s.captions.model),
            .model = s.captions.model,
            .proofread = proofread_live.load(.acquire),
            .language = try arena.dupe(u8, language(&lang_buf)),
        };
    }

    /// "" when a stop/cancel came during the start (quietly not listening).
    pub fn dictation_start(arena: std.mem.Allocator) ![]const u8 {
        const device = start(arena) catch |err| {
            if (err != error.Cancelled) return err;
            update("", "cancelled");
            return "";
        };
        App.runOnMain({}, struct {
            fn show(_: void) void {
                showOverlay();
            }
        }.show);
        return device;
    }

    pub fn dictation_stop(_: std.mem.Allocator) void {
        end(true);
    }

    pub fn dictation_cancel(_: std.mem.Allocator) void {
        end(false);
        if (App.getWindow("dictation")) |w| w.hide();
    }

    pub fn dictation_set_language(_: std.mem.Allocator, args: struct { language: []const u8 }) !void {
        setLanguage(args.language);
        const Edit = struct {
            lang: []const u8,
            pub fn apply(self: @This(), s: *main.Settings) void {
                s.dictation.language = self.lang;
            }
        };
        main.shared.update(main.io, gpa, Edit{ .lang = args.language }) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
    }

    pub fn dictation_set_proofread(_: std.mem.Allocator, args: struct { enabled: bool }) !void {
        proofread_live.store(args.enabled, .release);
        const Edit = struct {
            enabled: bool,
            pub fn apply(self: @This(), s: *main.Settings) void {
                s.dictation.proofread = self.enabled;
            }
        };
        main.shared.update(main.io, gpa, Edit{ .enabled = args.enabled }) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
    }
};
