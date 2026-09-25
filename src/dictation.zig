//! Voice dictation: microphone → whisper (re-transcribed as you speak) →
//! optional AI proofread → clipboard, shown in the dictation pill. The text
//! is copied, never auto-pasted (the user reviews it first). Port of
//! GhostPen's dictation.rs.

const std = @import("std");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");

const App = oriel.App;
const audio = oriel.audio_capture;
const log = std.log.scoped(.dictation);
const gpa = std.heap.smp_allocator;

const rate = models.sample_rate;
const read_chunk = rate / 10;

var mutex: std.Io.Mutex = .init;
var session: ?*Session = null;
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
    /// Capture on; cleared by stop/cancel.
    listening: std.atomic.Value(bool) = .init(true),
    /// Cancelled (Esc, or a newer session): the worker goes silent.
    aborted: std.atomic.Value(bool) = .init(false),
    /// Stop means finalize (transcribe → proofread → copy); false = cancel.
    finalize: std.atomic.Value(bool) = .init(true),
    buf_mutex: std.Io.Mutex = .init,
    samples: std.ArrayList(f32) = .empty,
    source: ?[:0]u8,
    model: []u8,
    capture_thread: std.Thread = undefined,
    level_thread: std.Thread = undefined,

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

    fn captureLoop(s: *Session) void {
        var stream = audio.Stream.open(s.source, "GhostPen dictation", rate) catch |err| {
            if (!s.aborted.load(.acquire)) update("Could not open the microphone.", "error");
            log.warn("open microphone: {s}", .{@errorName(err)});
            s.listening.store(false, .release);
            s.finalize.store(false, .release);
            s.aborted.store(true, .release);
            return;
        };
        defer stream.close();
        var buf: [read_chunk]f32 = undefined;
        while (s.listening.load(.acquire)) {
            stream.read(&buf) catch |err| {
                log.warn("capture: {s}", .{@errorName(err)});
                s.listening.store(false, .release);
                return;
            };
            s.buf_mutex.lockUncancelable(main.io);
            defer s.buf_mutex.unlock(main.io);
            s.samples.appendSlice(gpa, &buf) catch continue;
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
    /// Owns the session: frees it when done.
    fn workerLoop(s: *Session) void {
        defer s.destroy();
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
        s.capture_thread.join();
        s.level_thread.join();

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
        oriel.clipboard.writeText(final) catch |err| {
            var buf: [128]u8 = undefined;
            return update(std.fmt.bufPrint(&buf, "Clipboard error: {s}", .{@errorName(err)}) catch "Clipboard error", "error");
        };
        update(final, "done");
    }

    fn destroy(s: *Session) void {
        s.samples.deinit(gpa);
        if (s.source) |src| gpa.free(src);
        gpa.free(s.model);
        gpa.destroy(s);
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
    return if (session) |s| s.listening.load(.acquire) else false;
}

/// Start listening; returns the device name (in `arena`).
fn start(arena: std.mem.Allocator) ![]const u8 {
    const s = try main.shared.get(main.io, arena);
    const model = s.captions.model;
    if (!models.isDownloaded(main.io, gpa, model))
        return oriel.ipc.fail("Whisper model \"{s}\" isn't downloaded yet. Download it in Settings \u{2192} Captions.", .{model});

    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (session) |old| {
        if (old.listening.load(.acquire)) return oriel.ipc.fail("Dictation is already running.", .{});
        // A previous session still finalizing: the user moved on, silence it.
        old.aborted.store(true, .release);
        session = null;
    }

    const source = pickMicrophone(s.dictation.device) catch |err| return switch (err) {
        error.DeviceNotFound => oriel.ipc.fail("Microphone \"{s}\" not found.", .{s.dictation.device}),
        else => oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)}),
    };
    errdefer if (source) |src| gpa.free(src);
    models.ensure(main.io, gpa, model) catch |err| return oriel.ipc.fail("Could not load the whisper model \"{s}\" ({s}).", .{ model, @errorName(err) });
    proofread_live.store(s.dictation.proofread, .release);
    setLanguage(s.dictation.language);

    const sess = try gpa.create(Session);
    errdefer gpa.destroy(sess);
    sess.* = .{ .source = source, .model = try gpa.dupe(u8, model) };
    sess.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{sess});
    sess.level_thread = std.Thread.spawn(.{}, Session.levelLoop, .{sess}) catch |err| {
        sess.listening.store(false, .release);
        sess.capture_thread.join();
        return err;
    };
    const worker = std.Thread.spawn(.{}, Session.workerLoop, .{sess}) catch |err| {
        sess.listening.store(false, .release);
        sess.capture_thread.join();
        sess.level_thread.join();
        return err;
    };
    worker.detach(); // owns and frees the session
    session = sess;
    return arena.dupe(u8, if (source) |src| src else "default");
}

/// Stop listening: finalize (`finalize` true) or cancel.
fn end(finalize: bool) void {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    const s = session orelse return;
    session = null;
    if (!finalize) {
        s.finalize.store(false, .release);
        s.aborted.store(true, .release);
    }
    s.listening.store(false, .release);
}

fn showOverlay() void {
    const w = App.getWindow("dictation") orelse return;
    w.place(.{ .anchor = .bottom, .margin = 64 });
    w.show();
    w.focus();
    App.emit("ghostpen://dictation-show", .{});
}

/// The `--voice-input` hotkey / tray item: finish when listening, else show
/// the pill and start.
pub fn toggle() void {
    if (isRunning()) return end(true);
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
    pub fn dictation_list_devices(arena: std.mem.Allocator) ![]const []const u8 {
        const sources = audio.listSources(gpa) catch |err| return oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)});
        defer audio.freeSources(gpa, sources);
        var names: std.ArrayList([]const u8) = .empty;
        for (sources) |src| if (!src.monitor) try names.append(arena, try arena.dupe(u8, src.name));
        return names.items;
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
