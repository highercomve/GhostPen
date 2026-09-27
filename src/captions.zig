//! Live captions: system audio → whisper → (optional AI translation) →
//! `ghostpen://caption`, shown in a click-through overlay at the bottom of
//! the screen. Port of GhostPen's captions/mod.rs.

const std = @import("std");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");
const stt_server = @import("stt_server.zig");

const App = oriel.App;
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

pub fn init() void {
    // Loading the GPU backend can take seconds (Metal compiles its shaders
    // on a new build's first launch): off the main thread, so the tray and
    // windows come up at once. Captions and dictation load models later.
    if (std.Thread.spawn(.{}, models.init, .{main.io})) |t| t.detach() else |_| models.init(main.io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (main.shared.get(main.io, arena.allocator())) |s| translate_live.store(s.captions.aiTranslate, .release) else |_| {}
}

pub fn settingsChanged() void {
    init_translate: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const s = main.shared.get(main.io, arena.allocator()) catch break :init_translate;
        translate_live.store(s.captions.aiTranslate, .release);
    }
}

pub fn isRunning() bool {
    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    return if (session) |s| s.running.load(.acquire) else false;
}

/// A start in progress (device pick, model load): a second toggle is ignored.
var starting: std.atomic.Value(bool) = .init(false);

const Session = struct {
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

    /// All fields owned; on failure nothing leaks.
    fn create(source: [:0]const u8, c: @import("settings.zig").Captions) !*Session {
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
        if (s.worker_thread) |t| t.join();
        s.samples.deinit(gpa);
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
        s.samples.appendSlice(gpa, part) catch return;
        if (s.samples.items.len > max_buffer) {
            s.samples.replaceRangeAssumeCapacity(0, s.samples.items.len - max_buffer, &.{});
        }
    }

    fn captureLoop(s: *Session) void {
        if (models.test_audio != null) {
            s.opened.store(1, .release);
            return models.feedTestAudio(main.io, &s.running, s, append);
        }
        var stream = audio.Stream.open(s.source, "GhostPen captions", rate) catch |err| {
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
            const chunk = s.take() orelse continue;
            defer gpa.free(chunk);

            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const raw = models.transcribe(main.io, gpa, s.model, chunk, s.language, s.whisper_translate) catch |err| {
                emitError("Transcription failed ({s}).", .{@errorName(err)});
                continue;
            };
            defer gpa.free(raw);
            // Silence comes back as "[BLANK_AUDIO]": never show sound tags.
            const text = models.cleanTranscript(arena.allocator(), raw) catch continue;
            if (text.len == 0 or !s.running.load(.acquire)) continue;

            if (translate_live.load(.acquire)) {
                if (main.translateText(arena.allocator(), text, s.target_lang)) |t| {
                    App.emit("ghostpen://caption", .{ .text = t, .translated = true });
                    continue;
                } else |err| log.warn("translation failed ({s}); showing the original", .{@errorName(err)});
            }
            App.emit("ghostpen://caption", .{ .text = text, .translated = false });
        }
    }

    /// The buffered audio once there's a chunk's worth, else null. Caller frees.
    fn take(s: *Session) ?[]f32 {
        s.buf_mutex.lockUncancelable(main.io);
        defer s.buf_mutex.unlock(main.io);
        if (s.samples.items.len < s.chunk_samples) return null;
        const out = s.samples.toOwnedSlice(gpa) catch return null;
        return out;
    }
};

fn emitError(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log.warn("{s}", .{msg});
    App.emit("ghostpen://caption-error", msg);
}

/// The source to capture: the configured one (a case-insensitive substring of
/// its name or description), else the first system-audio (monitor) source.
/// Caller frees.
fn pickSource(device: []const u8) ![:0]u8 {
    const sources = try audio.listSources(gpa);
    defer audio.freeSources(gpa, sources);
    const want = std.mem.trim(u8, device, " \t");
    const auto = want.len == 0 or std.ascii.eqlIgnoreCase(want, "auto") or std.ascii.eqlIgnoreCase(want, "default");
    for (sources) |src| {
        if (auto) {
            if (src.monitor) return gpa.dupeZ(u8, src.name);
        } else if (containsIgnoreCase(src.name, want) or containsIgnoreCase(src.description, want)) {
            return gpa.dupeZ(u8, src.name);
        }
    }
    return if (auto) error.NoSystemAudioSource else error.DeviceNotFound;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Start a session; returns the device name (in `arena`). Slow work (device
/// list, model load, opening the source) runs without holding `mutex`.
fn start(arena: std.mem.Allocator) ![]const u8 {
    if (isRunning()) return oriel.ipc.fail("Captions are already running.", .{});
    if (starting.swap(true, .acq_rel)) return oriel.ipc.fail("Captions are already starting.", .{});
    defer starting.store(false, .release);

    const s = try main.shared.get(main.io, arena);
    const c = s.captions;
    if (!models.isDownloaded(main.io, gpa, c.model))
        return oriel.ipc.fail("Whisper model \"{s}\" isn't downloaded yet. Download it in Settings → Captions.", .{c.model});

    const source = if (models.test_audio != null) try gpa.dupeZ(u8, "test-audio") else pickSource(c.device) catch |err| return switch (err) {
        error.NoSystemAudioSource => oriel.ipc.fail("No system-audio source found (on macOS, install a loopback device such as BlackHole).", .{}),
        error.DeviceNotFound => oriel.ipc.fail("Audio device \"{s}\" not found.", .{c.device}),
        else => oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)}),
    };
    defer gpa.free(source);
    models.ensure(main.io, gpa, c.model) catch |err| return oriel.ipc.fail("Could not load the whisper model \"{s}\" ({s}).", .{ c.model, @errorName(err) });

    const sess = try Session.create(source, c);
    errdefer sess.destroy();
    translate_live.store(c.aiTranslate, .release);
    sess.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{sess});
    // Fail the start (like the Tauri app) when the source doesn't open.
    var waited: u32 = 0;
    while (sess.opened.load(.acquire) == 0 and waited < 3000) : (waited += 20) {
        main.io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
    if (sess.opened.load(.acquire) == 2) return oriel.ipc.fail("Could not open the audio source \"{s}\".", .{source});
    sess.worker_thread = try std.Thread.spawn(.{}, Session.workerLoop, .{sess});

    mutex.lockUncancelable(main.io);
    const old = session;
    session = sess;
    mutex.unlock(main.io);
    if (old) |o| o.destroy();
    return arena.dupe(u8, source);
}

/// Stop the running session. The threads are joined off the calling thread,
/// so the UI never waits for a transcription in flight.
fn stop() void {
    mutex.lockUncancelable(main.io);
    const s = session orelse {
        mutex.unlock(main.io);
        return;
    };
    session = null;
    mutex.unlock(main.io);
    s.running.store(false, .release);
    if (std.Thread.spawn(.{}, Session.destroy, .{s})) |t| t.detach() else |_| s.destroy();
}

/// Show the overlay with its controls (leave ghost mode), at the bottom.
pub fn open() void {
    const w = App.getWindow("captions") orelse return;
    w.setClickThrough(false);
    w.place(.{ .anchor = .bottom, .margin = 64 });
    w.show();
    w.focus();
    App.emit("ghostpen://captions-show", .{});
}

/// The `--captions` hotkey: stop and hide when running, else show and start.
pub fn toggle() void {
    if (starting.load(.acquire)) return;
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
    stop();
    App.runOnMain({}, struct {
        fn hide(_: void) void {
            if (App.getWindow("captions")) |w| w.hide();
        }
    }.hide);
}

fn startFromToggle() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = start(arena.allocator()) catch |err| {
        const msg = if (err == error.CommandFailed) oriel.ipc.errorText(err) else @errorName(err);
        App.emit("ghostpen://caption-error", msg);
        return;
    };
    App.emit("ghostpen://captions-show", .{});
}

const Status = struct {
    available: bool,
    running: bool,
    model_ready: bool,
    model: []const u8,
    translate: bool,
    target_lang: []const u8,
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
        };
    }

    pub fn captions_list_devices(arena: std.mem.Allocator) ![]const Device {
        return listDevices(arena, true);
    }

    pub fn captions_start(arena: std.mem.Allocator) ![]const u8 {
        const device = try start(arena);
        App.runOnMain({}, struct {
            fn show(_: void) void {
                const w = App.getWindow("captions") orelse return;
                w.place(.{ .anchor = .bottom, .margin = 64 });
                w.show();
            }
        }.show);
        return device;
    }

    pub fn captions_stop(_: std.mem.Allocator) void {
        stop();
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
                App.emitTo("settings", "ghostpen://whisper-download", p) catch {};
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
