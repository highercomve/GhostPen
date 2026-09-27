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
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");
const captions = @import("captions.zig");

const App = oriel.App;
const audio = oriel.audio_capture;
const log = std.log.scoped(.dictation);
const gpa = std.heap.smp_allocator;

const rate = models.sample_rate;
const read_chunk = rate / 10;

/// Guards `current` and `latest` (never held across slow work).
var mutex: std.Io.Mutex = .init;
var current: ?*Session = null;
var latest: ?*Session = null;
/// A start in progress (device pick, model load): a second toggle is ignored.
var starting: std.atomic.Value(bool) = .init(false);
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
    App.emit("ghostpen://dictation", .{ .text = text, .state = state });
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
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        return gpa.dupe(f32, s.samples.items);
    }

    fn len(s: *Session) usize {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        return s.samples.items.len;
    }

    fn append(s: *Session, part: []const f32) void {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        s.samples.appendSlice(gpa, part) catch {};
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
            App.emit("ghostpen://dictation-level", lvl);
        }
    }

    /// Re-transcribe the whole utterance while listening (each time a
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
            const samples = s.snapshot() catch continue;
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

        const final = if (proofread_live.load(.acquire)) blk: {
            update(transcript, "proofreading");
            break :blk main.proofread(arena.allocator(), transcript) catch |err| fallback: {
                log.warn("proofread failed ({s}); using the transcript", .{@errorName(err)});
                break :fallback transcript;
            };
        } else transcript;
        if (s.aborted.load(.acquire)) return;

        // Shares the menu's busy guard so clipboard writes can't interleave.
        if (main.busy.swap(true, .acq_rel)) return update("Another action is still running.", "error");
        defer main.busy.store(false, .release);
        const settings = main.shared.get(main.io, arena.allocator()) catch main.Settings{};
        if (settings.dictation.paste) {
            const pasted = main.pasteFromWindow("dictation", final, settings) catch |err| {
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
};

/// The configured microphone (substring match), else the default input.
fn pickMicrophone(device: []const u8) !?[:0]u8 {
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

pub fn isRunning() bool {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    return if (current) |s| s.listening.load(.acquire) else false;
}

/// Start listening; returns the device name (in `arena`). Slow work (device
/// list, model load, opening the microphone) runs without holding `mutex`.
fn start(arena: std.mem.Allocator) ![]const u8 {
    if (isRunning()) return oriel.ipc.fail("Dictation is already running.", .{});
    if (starting.swap(true, .acq_rel)) return oriel.ipc.fail("Dictation is already starting.", .{});
    defer starting.store(false, .release);

    const s = try main.shared.get(main.io, arena);
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
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
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
    const w = App.getWindow("dictation") orelse return;
    // Not where the user dragged it (Oriel drops the placement then).
    if (w.options.placement != null) w.place(.{ .anchor = .bottom, .margin = 64 });
    w.show();
    w.focus();
    App.emit("ghostpen://dictation-show", .{});
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
    _ = start(arena.allocator()) catch |err| {
        update(if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err), "error");
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

    pub fn dictation_start(arena: std.mem.Allocator) ![]const u8 {
        const device = try start(arena);
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
