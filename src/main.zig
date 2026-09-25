//! GhostPen on Oriel: AI text editing anywhere on the desktop.
//!
//! Highlight text in any app, press the hotkey (or click the tray icon),
//! pick an action; the result is pasted back in place. Also a Playground,
//! OCR of clipboard images, live captions and voice dictation.
//!
//! The commands and events keep the Tauri version's names and JSON shapes,
//! so the React frontend is GhostPen's own.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const ai = @import("ai.zig");
const settings_mod = @import("settings.zig");
const store = @import("store.zig");
const image = @import("image.zig");
const captions = @import("captions.zig");
const dictation = @import("dictation.zig");

const App = oriel.App;
pub const Settings = settings_mod.Settings;
const log = std.log.scoped(.ghostpen);
const gpa = std.heap.smp_allocator;

// ---- shared state ----------------------------------------------------------------------

pub var io: std.Io = undefined;
pub var shared: store.Shared = .init(gpa);

/// What the menu works on (the clipboard after the trigger's copy), and what
/// the clipboard held before (restored after pasting). Owned by `gpa`.
const Content = union(enum) {
    empty,
    text: []u8,
    image: []u8, // PNG

    fn deinit(self: Content) void {
        switch (self) {
            .empty => {},
            .text, .image => |b| gpa.free(b),
        }
    }
};

var state_mutex: std.Io.Mutex = .init;
var current_input: Content = .empty;
var snapshot: Content = .empty;

fn replace(slot: *Content, new: Content) void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    slot.deinit();
    slot.* = new;
}

/// One AI operation at a time (the Tauri app's busy guard).
pub var busy: std.atomic.Value(bool) = .init(false);

fn acquireBusy() !void {
    if (busy.swap(true, .acq_rel)) return oriel.ipc.fail("Another action is still running.", .{});
}

/// Synthetic copy/paste works here (probed once at startup); without it
/// GhostPen runs in manual-copy mode (the user copies/pastes).
var input_available = false;

fn useSynthetic(s: Settings) bool {
    return input_available or s.forceSynthetic;
}

fn sessionName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows",
        .macos => "macos",
        else => if (std.c.getenv("WAYLAND_DISPLAY") != null) "wayland" else "x11",
    };
}

// ---- types sent to the page (the Tauri DTOs) --------------------------------------------

const Status = struct {
    session: []const u8,
    clipboard_backend: []const u8,
    input_available: bool,
    manual_mode: bool,
    active_profile: []const u8,
    active_model: []const u8,
};

/// `{kind: "empty"} | {kind: "text", text} | {kind: "image", preview, width, height}`.
const SelectionInfo = struct {
    kind: []const u8,
    text: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,

    pub fn jsonStringify(self: SelectionInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(self.kind);
        if (self.text) |t| {
            try jw.objectField("text");
            try jw.write(t);
        }
        if (self.preview) |p| {
            try jw.objectField("preview");
            try jw.write(p);
            try jw.objectField("width");
            try jw.write(self.width orelse 0);
            try jw.objectField("height");
            try jw.write(self.height orelse 0);
        }
        try jw.endObject();
    }
};

const ProcessResult = struct { output: []const u8, pasted: bool, manual: bool };

pub const Events = struct {
    @"ghostpen://show": struct {},
    @"ghostpen://chunk": []const u8,
    @"ghostpen://done": []const u8,
    @"ghostpen://error": []const u8,
    @"ghostpen://captions-show": struct {},
    @"ghostpen://caption": struct { text: []const u8, translated: bool },
    @"ghostpen://caption-error": []const u8,
    @"ghostpen://dictation": struct { text: []const u8, state: []const u8 },
    @"ghostpen://dictation-level": f32,
    @"ghostpen://dictation-show": struct {},
};

// ---- AI helpers ------------------------------------------------------------------------

fn parseLevel(level: ?[]const u8) ai.Level {
    return std.meta.stringToEnum(ai.Level, level orelse "balanced") orelse .balanced;
}

const Resolved = struct { system: []const u8, profile: settings_mod.Profile };

/// System prompt and profile for an action id (built-in or custom).
fn resolveAction(arena: std.mem.Allocator, s: Settings, action: []const u8, lang: ?[]const u8, level: ai.Level) !Resolved {
    var profile = s.activeProfile();
    if (try ai.builtinPrompt(arena, action, lang, level)) |p| return .{ .system = p, .profile = profile };
    for (s.customActions) |c| if (std.mem.eql(u8, c.id, action)) {
        if (c.model.len > 0) profile.model = c.model;
        return .{ .system = c.prompt, .profile = profile };
    };
    return oriel.ipc.fail("Unknown action: {s}", .{action});
}

fn complete(arena: std.mem.Allocator, req: ai.Request) ![]const u8 {
    var diag: ai.Diag = .{};
    return ai.complete(io, gpa, arena, req, &diag) catch |err| switch (err) {
        error.AiFailed => oriel.ipc.fail("{s}", .{diag.message}),
        else => err,
    };
}

/// AI translation for captions (runs on the captions worker).
pub fn translateText(arena: std.mem.Allocator, text: []const u8, target: []const u8) ![]const u8 {
    const s = try shared.get(io, arena);
    const system = (try ai.builtinPrompt(arena, "translate", target, .balanced)).?;
    var diag: ai.Diag = .{};
    return ai.complete(io, gpa, arena, .{ .profile = s.activeProfile(), .system = system, .user = .{ .text = text } }, &diag);
}

/// The built-in proofread prompt, for dictation.
pub fn proofread(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const s = try shared.get(io, arena);
    const system = (try ai.builtinPrompt(arena, "proofread", null, .balanced)).?;
    var diag: ai.Diag = .{};
    return ai.complete(io, gpa, arena, .{ .profile = s.activeProfile(), .system = system, .user = .{ .text = text } }, &diag);
}

/// Put the result on the clipboard, paste it into the app underneath (hide
/// the menu first so it gets the keystroke), then restore what the
/// clipboard held before.
fn deliver(output: []const u8, s: Settings) !ProcessResult {
    oriel.clipboard.writeText(output) catch |err| return oriel.ipc.fail("Could not write the clipboard ({s}).", .{@errorName(err)});
    if (!useSynthetic(s)) return .{ .output = output, .pasted = false, .manual = true };

    App.runOnMain({}, struct {
        fn hide(_: void) void {
            if (App.getWindow("main")) |w| w.hide();
        }
    }.hide);
    io.sleep(.fromMilliseconds(150), .awake) catch {};
    oriel.input.paste() catch |err| {
        log.warn("paste failed ({s}); the result is on the clipboard", .{@errorName(err)});
        return .{ .output = output, .pasted = false, .manual = true };
    };

    // Restore after the target app has read the clipboard.
    const t = std.Thread.spawn(.{}, restoreSnapshot, .{s.restoreDelayMs}) catch return .{ .output = output, .pasted = true, .manual = false };
    t.detach();
    return .{ .output = output, .pasted = true, .manual = false };
}

fn restoreSnapshot(delay_ms: u32) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
    state_mutex.lockUncancelable(io);
    const snap = snapshot;
    snapshot = .empty;
    state_mutex.unlock(io);
    defer snap.deinit();
    switch (snap) {
        .empty => {},
        .text => |t| oriel.clipboard.writeText(t) catch |err| log.warn("restore clipboard: {s}", .{@errorName(err)}),
        .image => |png| oriel.clipboard.writeImage(png) catch |err| log.warn("restore clipboard image: {s}", .{@errorName(err)}),
    }
}

// ---- the trigger (hotkey / tray / --trigger) -------------------------------------------

/// Snapshot the clipboard, copy the selection, then show the menu. Runs on
/// its own thread: clipboard reads and the copy delay must not block the UI.
fn triggerMenuFlow() void {
    const t = std.Thread.spawn(.{}, triggerWorker, .{}) catch |err| {
        log.err("trigger: {s}", .{@errorName(err)});
        return;
    };
    t.detach();
}

fn triggerWorker() void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const s = shared.get(io, arena_state.allocator()) catch Settings{};

    if (useSynthetic(s)) {
        replace(&snapshot, readClipboard());
        oriel.input.copy() catch |err| log.warn("synthetic copy failed: {s}", .{@errorName(err)});
        io.sleep(.fromMilliseconds(80), .awake) catch {};
    } else {
        replace(&snapshot, .empty);
    }
    replace(&current_input, .empty);

    App.runOnMain({}, struct {
        fn show(_: void) void {
            showWindow("main", true);
            App.emitTo("main", "ghostpen://show", .{}) catch {};
        }
    }.show);
}

/// The clipboard now: text when there is some, else an image.
fn readClipboard() Content {
    if (oriel.clipboard.readText(gpa)) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len > 0) return .{ .text = text };
        gpa.free(text);
    } else |_| {}
    if (oriel.clipboard.readImage(gpa)) |maybe| {
        if (maybe) |png| return .{ .image = png };
    } else |_| {}
    return .empty;
}

/// Show (and focus) a window by label, centering the menu.
pub fn showWindow(label: []const u8, center: bool) void {
    const w = App.getWindow(label) orelse return;
    if (center) w.center();
    w.show();
    w.focus();
}

// ---- commands ----------------------------------------------------------------------------

pub const Commands = struct {
    pub const async_commands = .{
        "get_selection",           "extract_image_text",  "process_ai_action",     "process_ai_custom",
        "process_text",            "process_text_stream", "fetch_models",          "captions_start",
        "captions_download_model", "dictation_start",     "captions_list_devices", "dictation_list_devices",
    };

    pub fn get_settings(arena: std.mem.Allocator) !Settings {
        return shared.get(io, arena);
    }

    pub fn save_settings(arena: std.mem.Allocator, args: struct { settings: Settings }) !void {
        shared.set(io, gpa, args.settings) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
        captions.settingsChanged();
        dictation.settingsChanged();
        const failed = registerHotkeys(arena, args.settings);
        if (failed.len > 0) return oriel.ipc.fail("Settings saved, but a hotkey wasn't registered: {s}", .{failed});
    }

    pub fn fetch_models(arena: std.mem.Allocator, args: struct { baseUrl: []const u8, apiKey: []const u8 = "" }) ![]const []const u8 {
        var diag: ai.Diag = .{};
        return ai.listModels(io, gpa, arena, args.baseUrl, args.apiKey, &diag) catch |err| switch (err) {
            error.AiFailed => oriel.ipc.fail("{s}", .{diag.message}),
            else => err,
        };
    }

    pub fn get_status(arena: std.mem.Allocator) !Status {
        const s = try shared.get(io, arena);
        const p = s.activeProfile();
        return .{
            .session = sessionName(),
            .clipboard_backend = "oriel",
            .input_available = input_available,
            .manual_mode = !useSynthetic(s),
            .active_profile = p.name,
            .active_model = p.model,
        };
    }

    /// The clipboard (after the trigger's copy): text first, then an image.
    pub fn get_selection(arena: std.mem.Allocator) !SelectionInfo {
        const content = readClipboard();
        const info: SelectionInfo = switch (content) {
            .empty => .{ .kind = "empty" },
            .text => |t| .{ .kind = "text", .text = try arena.dupe(u8, t) },
            .image => |png| blk: {
                const size = image.pngSize(png) orelse image.Size{ .width = 0, .height = 0 };
                const thumb = image.fitWithin(gpa, png, 512) catch |err| {
                    content.deinit();
                    return oriel.ipc.fail("Could not read the image ({s}).", .{@errorName(err)});
                };
                defer gpa.free(thumb);
                const uri = try image.dataUri(gpa, thumb);
                defer gpa.free(uri);
                break :blk .{ .kind = "image", .preview = try arena.dupe(u8, uri), .width = size.width, .height = size.height };
            },
        };
        replace(&current_input, content);
        return info;
    }

    /// OCR of the selected image through the vision model; the text becomes
    /// the working selection.
    pub fn extract_image_text(arena: std.mem.Allocator) ![]const u8 {
        try acquireBusy();
        defer busy.store(false, .release);
        const s = try shared.get(io, arena);

        state_mutex.lockUncancelable(io);
        const png: ?[]u8 = switch (current_input) {
            .image => |p| arena.dupe(u8, p) catch null,
            else => null,
        };
        state_mutex.unlock(io);
        const src = png orelse return oriel.ipc.fail("No image selected.", .{});

        const scaled = image.fitWithin(gpa, src, s.ocr.maxDimension) catch |err| return oriel.ipc.fail("Could not read the image ({s}).", .{@errorName(err)});
        defer gpa.free(scaled);
        var profile = s.activeProfile();
        if (s.ocr.modelOverride.len > 0) profile.model = s.ocr.modelOverride;
        const system = if (std.mem.trim(u8, s.ocr.systemPrompt, " \t\r\n").len > 0) s.ocr.systemPrompt else ai.ocr_system_prompt;

        var diag: ai.Diag = .{};
        const text = ai.complete(io, gpa, arena, .{
            .profile = profile,
            .system = system,
            .user = .{ .image_with_text = .{ .text = ai.ocr_user_text, .png = scaled } },
        }, &diag) catch |err| switch (err) {
            error.AiFailed => return if (std.mem.startsWith(u8, diag.message, "API 4"))
                oriel.ipc.fail("The active model may not support images (try a vision model like gemma4:e4b). {s}", .{diag.message})
            else
                oriel.ipc.fail("{s}", .{diag.message}),
            else => return err,
        };
        replace(&current_input, .{ .text = try gpa.dupe(u8, text) });
        return text;
    }

    pub fn copy_text(_: std.mem.Allocator, args: struct { text: []const u8 }) !void {
        oriel.clipboard.writeText(args.text) catch |err| return oriel.ipc.fail("Could not write the clipboard ({s}).", .{@errorName(err)});
    }

    pub fn process_ai_action(arena: std.mem.Allocator, args: struct { action: []const u8, targetLang: ?[]const u8 = null, level: ?[]const u8 = null }) !ProcessResult {
        try acquireBusy();
        defer busy.store(false, .release);
        const s = try shared.get(io, arena);
        const text = try selectionText(arena);
        const r = try resolveAction(arena, s, args.action, args.targetLang, parseLevel(args.level));
        const output = try complete(arena, .{ .profile = r.profile, .system = r.system, .user = .{ .text = text } });
        return deliver(output, s);
    }

    pub fn process_ai_custom(arena: std.mem.Allocator, args: struct { instruction: []const u8 }) !ProcessResult {
        try acquireBusy();
        defer busy.store(false, .release);
        const s = try shared.get(io, arena);
        const text = try selectionText(arena);
        const system = try ai.instructionPrompt(arena, args.instruction);
        const output = try complete(arena, .{ .profile = s.activeProfile(), .system = system, .user = .{ .text = text } });
        return deliver(output, s);
    }

    /// Playground: transform text directly, no clipboard.
    pub fn process_text(arena: std.mem.Allocator, args: struct { action: []const u8, targetLang: ?[]const u8 = null, level: ?[]const u8 = null, text: []const u8 }) ![]const u8 {
        const s = try shared.get(io, arena);
        const r = try resolveAction(arena, s, args.action, args.targetLang, parseLevel(args.level));
        return complete(arena, .{ .profile = r.profile, .system = r.system, .user = .{ .text = args.text } });
    }

    /// Streaming variant: `ghostpen://chunk` per delta, then `done` (the
    /// final text, which replaces the chunks) or `error`, to the Playground.
    pub fn process_text_stream(arena: std.mem.Allocator, args: struct { action: []const u8, targetLang: ?[]const u8 = null, level: ?[]const u8 = null, text: []const u8 }) !void {
        const s = try shared.get(io, arena);
        const r = try resolveAction(arena, s, args.action, args.targetLang, parseLevel(args.level));
        const Emit = struct {
            fn chunk(_: void, delta: []const u8) void {
                App.emitTo("playground", "ghostpen://chunk", delta) catch {};
            }
        };
        var diag: ai.Diag = .{};
        const final = ai.completeStream(io, gpa, arena, .{ .profile = r.profile, .system = r.system, .user = .{ .text = args.text } }, {}, Emit.chunk, &diag) catch |err| {
            const msg = if (err == error.AiFailed) diag.message else @errorName(err);
            App.emitTo("playground", "ghostpen://error", msg) catch {};
            return;
        };
        App.emitTo("playground", "ghostpen://done", final) catch {};
    }

    pub fn open_playground(_: std.mem.Allocator) void {
        showWindow("playground", false);
    }

    pub fn open_settings(_: std.mem.Allocator) void {
        showWindow("settings", false);
    }

    // Captions and dictation live in their own modules.
    pub const open_captions = captions.Commands.open_captions;
    pub const captions_status = captions.Commands.captions_status;
    pub const captions_list_devices = captions.Commands.captions_list_devices;
    pub const captions_start = captions.Commands.captions_start;
    pub const captions_stop = captions.Commands.captions_stop;
    pub const captions_set_click_through = captions.Commands.captions_set_click_through;
    pub const captions_set_translate = captions.Commands.captions_set_translate;
    pub const captions_download_model = captions.Commands.captions_download_model;
    pub const dictation_list_devices = dictation.Commands.dictation_list_devices;
    pub const dictation_status = dictation.Commands.dictation_status;
    pub const dictation_start = dictation.Commands.dictation_start;
    pub const dictation_stop = dictation.Commands.dictation_stop;
    pub const dictation_cancel = dictation.Commands.dictation_cancel;
    pub const dictation_set_language = dictation.Commands.dictation_set_language;
    pub const dictation_set_proofread = dictation.Commands.dictation_set_proofread;
};

fn selectionText(arena: std.mem.Allocator) ![]const u8 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    return switch (current_input) {
        .text => |t| try arena.dupe(u8, t),
        .image => oriel.ipc.fail("An image is selected: extract its text first.", .{}),
        .empty => oriel.ipc.fail("Nothing selected: highlight some text, then trigger GhostPen.", .{}),
    };
}

// ---- hotkeys, tray, launch flags -------------------------------------------------------

/// Triggers of the registered hotkeys (the registration keeps pointers to them).
var hotkey_arena: std.heap.ArenaAllocator = .init(gpa);

/// (Re)register the three hotkeys; returns the failures ("" when none).
fn registerHotkeys(arena: std.mem.Allocator, s: Settings) []const u8 {
    const binds = [_]struct { id: []const u8, trigger: []const u8 }{
        .{ .id = "menu", .trigger = s.hotkey },
        .{ .id = "dictation", .trigger = s.dictationHotkey },
        .{ .id = "captions", .trigger = s.captionsHotkey },
    };
    for (binds) |b| _ = oriel.global_shortcut.unregister(b.id);
    _ = hotkey_arena.reset(.retain_capacity);
    var failed: std.ArrayList(u8) = .empty;
    for (binds) |b| {
        if (std.mem.trim(u8, b.trigger, " ").len == 0) continue;
        const trigger = hotkey_arena.allocator().dupe(u8, b.trigger) catch continue;
        oriel.global_shortcut.register(gpa, .{ .id = b.id, .description = b.id, .trigger = trigger }, &onHotkey) catch |err| {
            failed.print(arena, "{s}{s} ({s}: {s})", .{ if (failed.items.len > 0) "; " else "", b.trigger, b.id, @errorName(err) }) catch {};
        };
    }
    return failed.items;
}

fn onHotkey(id: []const u8) void {
    if (std.mem.eql(u8, id, "menu")) {
        triggerMenuFlow();
    } else if (std.mem.eql(u8, id, "dictation")) {
        dictation.toggle();
    } else if (std.mem.eql(u8, id, "captions")) {
        captions.toggle();
    }
}

var tray: ?*oriel.tray.Tray = null;

fn onTrayMenu(id: []const u8, _: ?bool) void {
    const eql = std.mem.eql;
    if (eql(u8, id, "show")) {
        triggerMenuFlow();
    } else if (eql(u8, id, "dictate")) {
        dictation.toggle();
    } else if (eql(u8, id, "captions")) {
        captions.open();
    } else if (eql(u8, id, "playground")) {
        showWindow("playground", false);
    } else if (eql(u8, id, "settings")) {
        showWindow("settings", false);
    } else if (eql(u8, id, "quit")) {
        App.quit(0);
    }
}

/// `--trigger`, `--voice-input`, `--captions`, `--settings`, `--playground`
/// (from the first launch or a later one: e.g. a compositor keybinding).
fn handleArgs(args: []const []const u8) void {
    const eql = std.mem.eql;
    for (args) |a| {
        if (eql(u8, a, "--trigger")) {
            triggerMenuFlow();
        } else if (eql(u8, a, "--voice-input")) {
            dictation.toggle();
        } else if (eql(u8, a, "--captions")) {
            captions.toggle();
        } else if (eql(u8, a, "--settings")) {
            showWindow("settings", false);
        } else if (eql(u8, a, "--playground")) {
            showWindow("playground", false);
        }
    }
}

var launch_args: []const []const u8 = &.{};

fn setup() !void {
    shared.load(io, gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try shared.get(io, arena.allocator());

    // The other windows: created hidden, hidden again when closed.
    const windows = [_]App.WindowOptions{
        .{ .label = "settings", .title = "GhostPen Settings", .url = "index.html#/settings", .width = 540, .height = 680, .visible = false, .hide_on_close = true },
        .{ .label = "playground", .title = "GhostPen Playground", .url = "index.html#/playground", .width = 640, .height = 620, .visible = false, .hide_on_close = true },
        .{ .label = "dictation", .title = "GhostPen Dictation", .url = "index.html#/dictation", .width = 520, .height = 200, .resizable = false, .decorations = false, .visible = false, .transparent = true, .always_on_top = true, .skip_taskbar = true, .placement = .{ .anchor = .bottom, .margin = 64 }, .hide_on_close = true },
        .{ .label = "captions", .title = "GhostPen Captions", .url = "index.html#/captions", .width = 900, .height = 170, .decorations = false, .visible = false, .transparent = true, .always_on_top = true, .skip_taskbar = true, .placement = .{ .anchor = .bottom, .margin = 64 }, .hide_on_close = true, .focus_on_show = false },
    };
    for (windows) |w| _ = App.openWindow(w) catch |err| log.err("window {s}: {s}", .{ w.label, @errorName(err) });

    tray = oriel.tray.Tray.create(gpa, .{
        .id = settings_mod.app_id,
        .title = "GhostPen",
        .tooltip = "GhostPen",
        .icon = .{ .png = app.icon_bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show menu" } },
            .{ .item = .{ .id = "dictate", .label = "Dictation" } },
            .{ .item = .{ .id = "captions", .label = "Captions" } },
            .{ .item = .{ .id = "playground", .label = "Playground" } },
            .{ .item = .{ .id = "settings", .label = "Settings" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit" } },
        },
        .on_menu = onTrayMenu,
        .on_activate = triggerMenuFlow,
    }) catch |err| blk: {
        log.warn("no tray icon ({s}); use the hotkeys or `ghostpen-oriel --trigger`", .{@errorName(err)});
        break :blk null;
    };

    const failed = registerHotkeys(arena.allocator(), s);
    if (failed.len > 0) log.warn("hotkeys not registered: {s} (bind `ghostpen-oriel --trigger` in your desktop instead)", .{failed});

    // Synthetic input available? (Probed off the UI thread: it may talk to the compositor.)
    if (std.Thread.spawn(.{}, probeInput, .{})) |t| t.detach() else |_| {}

    captions.init();
    dictation.init();
    handleArgs(launch_args);
}

fn probeInput() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const check = oriel.input.check(arena.allocator(), .{ .io = io, .icon_png = app.icon_bytes }) catch return;
    input_available = check.ok;
    if (!check.ok) log.info("synthetic input unavailable ({s}): manual-copy mode", .{check.detail});
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print(
                \\Usage: ghostpen-oriel [--trigger | --voice-input | --captions | --settings | --playground | --tray]
                \\
                \\A running GhostPen receives these flags from later launches, so a
                \\desktop keybinding can run e.g. `ghostpen-oriel --trigger`.
                \\
            , .{});
            return 0;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("ghostpen-oriel 0.1.0\n", .{});
            return 0;
        }
    }
    launch_args = args[1..];

    // Test hook: $GHOSTPEN_TEST_AUDIO (16 kHz mono PCM16 WAV) replaces the
    // sound server for captions and dictation.
    if (init.environ_map.get("GHOSTPEN_TEST_AUDIO")) |wav| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, wav, init.arena.allocator(), .limited(256 << 20));
        @import("models.zig").test_audio = try @import("models.zig").decodeWav(init.arena.allocator(), data);
    }

    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = settings_mod.app_id,
        .title = "GhostPen",
        // The menu: a frameless floating panel, shown by the trigger.
        .width = 320,
        .height = 620,
        .resizable = false,
        .decorations = false,
        .always_on_top = true,
        .skip_taskbar = true,
        .placement = .{},
        .show_main_window = false,
        .on_close = .hide,
        .assets = app.assets,
        .dev = app.dev,
        .icon = app.icon_bytes,
        .permissions = app.permissions,
        .setup = &setup,
        .on_second_instance = &handleArgs,
    });
}
