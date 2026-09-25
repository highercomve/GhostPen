//! Live captions: system audio → whisper → (optional AI translation) →
//! `ghostpen://caption`, shown in a click-through overlay at the bottom of
//! the screen. Port of GhostPen's captions/mod.rs.

const std = @import("std");
const oriel = @import("oriel");
const main = @import("main.zig");
const models = @import("models.zig");

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
    models.init(main.io);
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

const Session = struct {
    running: std.atomic.Value(bool) = .init(true),
    capture_thread: std.Thread = undefined,
    worker_thread: std.Thread = undefined,
    buf_mutex: std.Io.Mutex = .init,
    samples: std.ArrayList(f32) = .empty,
    source: ?[:0]u8 = null,
    model: []u8,
    language: []u8,
    whisper_translate: bool,
    chunk_samples: usize,
    target_lang: []u8,

    fn destroy(s: *Session) void {
        s.running.store(false, .release);
        s.capture_thread.join();
        s.worker_thread.join();
        s.samples.deinit(gpa);
        if (s.source) |src| gpa.free(src);
        gpa.free(s.model);
        gpa.free(s.language);
        gpa.free(s.target_lang);
        gpa.destroy(s);
    }

    /// Owns the audio stream: opened, read and closed on this thread.
    fn captureLoop(s: *Session) void {
        var stream = audio.Stream.open(s.source, "GhostPen captions", rate) catch |err| {
            emitError("Could not open the audio source ({s}).", .{@errorName(err)});
            s.running.store(false, .release);
            return;
        };
        defer stream.close();
        var buf: [read_chunk]f32 = undefined;
        while (s.running.load(.acquire)) {
            stream.read(&buf) catch |err| {
                emitError("Audio capture stopped ({s}).", .{@errorName(err)});
                s.running.store(false, .release);
                return;
            };
            s.buf_mutex.lockUncancelable(main.io);
            defer s.buf_mutex.unlock(main.io);
            s.samples.appendSlice(gpa, &buf) catch continue;
            if (s.samples.items.len > max_buffer) {
                s.samples.replaceRangeAssumeCapacity(0, s.samples.items.len - max_buffer, &.{});
            }
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
            const text = std.mem.trim(u8, raw, " \t\r\n");
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

/// Start a session; returns the device name (in `arena`).
fn start(arena: std.mem.Allocator) ![]const u8 {
    const s = try main.shared.get(main.io, arena);
    const c = s.captions;
    if (!models.isDownloaded(main.io, gpa, c.model))
        return oriel.ipc.fail("Whisper model \"{s}\" isn't downloaded yet. Download it in Settings → Captions.", .{c.model});

    mutex.lockUncancelable(main.io);
    defer mutex.unlock(main.io);
    if (session) |old| {
        if (old.running.load(.acquire)) return oriel.ipc.fail("Captions are already running.", .{});
        session = null;
        old.destroy();
    }

    const source = pickSource(c.device) catch |err| return switch (err) {
        error.NoSystemAudioSource => oriel.ipc.fail("No system-audio source found (on macOS, install a loopback device such as BlackHole).", .{}),
        error.DeviceNotFound => oriel.ipc.fail("Audio device \"{s}\" not found.", .{c.device}),
        else => oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)}),
    };
    errdefer gpa.free(source);
    models.ensure(main.io, gpa, c.model) catch |err| return oriel.ipc.fail("Could not load the whisper model \"{s}\" ({s}).", .{ c.model, @errorName(err) });

    const sess = try gpa.create(Session);
    errdefer gpa.destroy(sess);
    sess.* = .{
        .source = source,
        .model = try gpa.dupe(u8, c.model),
        .language = try gpa.dupe(u8, c.language),
        .whisper_translate = c.whisperTranslate,
        .chunk_samples = @max(rate, @as(usize, @intFromFloat(c.chunkSeconds * @as(f64, @floatFromInt(rate))))),
        .target_lang = try gpa.dupe(u8, c.targetLang),
    };
    translate_live.store(c.aiTranslate, .release);
    sess.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{sess});
    sess.worker_thread = std.Thread.spawn(.{}, Session.workerLoop, .{sess}) catch |err| {
        sess.running.store(false, .release);
        sess.capture_thread.join();
        return err;
    };
    session = sess;
    return arena.dupe(u8, source);
}

fn stop() void {
    mutex.lockUncancelable(main.io);
    const s = session orelse {
        mutex.unlock(main.io);
        return;
    };
    session = null;
    mutex.unlock(main.io);
    s.destroy();
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

    pub fn captions_list_devices(arena: std.mem.Allocator) ![]const []const u8 {
        const sources = audio.listSources(gpa) catch |err| return oriel.ipc.fail("Could not list audio devices ({s}).", .{@errorName(err)});
        defer audio.freeSources(gpa, sources);
        const names = try arena.alloc([]const u8, sources.len);
        for (sources, names) |src, *n| n.* = try arena.dupe(u8, src.name);
        return names;
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
        var message: []const u8 = "";
        models.download(main.io, gpa, arena, id, &message) catch |err| return oriel.ipc.fail("{s}", .{if (message.len > 0) message else @errorName(err)});
    }
};
