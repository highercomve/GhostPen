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
const local_llm = @import("local_llm.zig");
const llm_models = @import("llm_models.zig");
const llm_helper = @import("llm_helper.zig");
const web_page = @import("web_page.zig");
const updates = @import("updates.zig");

const App = oriel.App;

/// Logs go to stderr and to a file: `~/.local/share/<id>/app.log` (Linux),
/// `%LOCALAPPDATA%\<id>\app.log` (Windows), `~/Library/Logs/<id>/app.log`
/// (macOS), where an app started from the desktop leaves them.
pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
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

/// Synthetic copy/paste works here (probed once at startup, off the UI
/// thread); without it GhostPen runs in manual-copy mode.
var input_available: std.atomic.Value(bool) = .init(false);
var input_probed: std.atomic.Value(bool) = .init(false);

fn useSynthetic(s: Settings) bool {
    return input_available.load(.acquire) or s.forceSynthetic;
}

/// Wait (briefly) for the startup probe: a `--trigger` at launch must not
/// fall into manual mode just because the probe hasn't finished.
fn waitForInputProbe() void {
    var waited: u32 = 0;
    while (!input_probed.load(.acquire) and waited < 2000) : (waited += 20) {
        io.sleep(.fromMilliseconds(20), .awake) catch return;
    }
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

const ProcessResult = struct {
    output: []const u8,
    pasted: bool,
    manual: bool,
    /// Shown in the menu instead of pasted (Shift+action, or Settings).
    shown: bool = false,
};

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
    /// What a menu action is doing (to the menu): loading the built-in
    /// model, reading the text, writing (tokens so far), or waiting for a
    /// connected service.
    @"ghostpen://ai-progress": AiProgress,
    /// Local model downloads (to the Settings window).
    @"ghostpen://llm-download": llm_models.Progress,
    /// Speech (whisper) model downloads (Settings).
    @"ghostpen://whisper-download": llm_models.Progress,
    /// Update download progress (Settings).
    @"ghostpen://update-progress": updates.Progress,
};

// ---- built-in models (GhostPen runs them) -------------------------------------------------------

var environ_map: *const std.process.Environ.Map = undefined;
/// This executable (the runner is it, in helper mode).
var self_exe: ?[]const u8 = null;

pub fn llmDirs(arena: std.mem.Allocator) !llm_models.Dirs {
    const base = try oriel.store.dataDir(arena, "GhostPen");
    return llm_models.dirs(arena, try std.fs.path.join(arena, &.{ base, "models" }), environ_map);
}

/// `ai.local_resolver`: the runner's configuration for a local profile.
fn resolveLocal(arena: std.mem.Allocator, profile: settings_mod.Profile, diag: *ai.Diag) ai.Error!local_llm.Config {
    const s = shared.get(io, arena) catch Settings{};
    const d = llmDirs(arena) catch return error.OutOfMemory;
    const model = if (profile.model.len > 0) profile.model else llm_models.default_id;
    const path = llm_models.resolve(io, arena, d, model) orelse {
        diag.message = std.fmt.allocPrint(arena, "The model \"{s}\" isn't downloaded: download it in Settings → Built-in models.", .{model}) catch return error.OutOfMemory;
        return error.AiFailed;
    };
    const exe = self_exe orelse {
        diag.message = "Can't find GhostPen's executable to start the built-in model.";
        return error.AiFailed;
    };
    return .{
        .exe = exe,
        .model = path,
        .mmproj = llm_models.projector(io, arena, d, path),
        // Always, so the app and the model service share one runner (a
        // different configuration would restart it).
        .embed_model = llm_models.embeddingModel(io, arena, d),
        .ctx = s.localLlm.ctxTokens,
        .gpu = s.localLlm.gpu,
        .moe_pct = s.localLlm.moePct,
        .idle_minutes = s.localLlm.idleMinutes,
    };
}

/// The built-in model's runner configuration, whatever profile is active:
/// the first Built-in profile's model, else the default one. What the model
/// service shares with other apps.
pub fn builtinConfig(arena: std.mem.Allocator, diag: *ai.Diag) ai.Error!local_llm.Config {
    const s = shared.get(io, arena) catch Settings{};
    for (s.profiles) |p| if (p.isLocal()) return serviceCtx(s, try resolveLocal(arena, p, diag));
    return serviceCtx(s, try resolveLocal(arena, .{ .id = "this-computer", .name = "Built-in", .provider = "local", .model = llm_models.default_id }, diag));
}

/// The model service's own context setting (Settings → Model & speech
/// service), when set, over the built-in model's.
fn serviceCtx(s: Settings, cfg: local_llm.Config) local_llm.Config {
    var out = cfg;
    if (s.server.ctxTokens > 0) out.ctx = s.server.ctxTokens;
    return out;
}

/// The model service's configuration for a model selected by an API client.
/// `llm_models.resolve` accepts catalog IDs and installed `file:` models.
pub fn builtinConfigForModel(arena: std.mem.Allocator, model: []const u8, diag: *ai.Diag) ai.Error!local_llm.Config {
    const s = shared.get(io, arena) catch Settings{};
    return serviceCtx(s, try resolveLocal(arena, .{ .id = "model-service", .name = "Model service", .provider = "local", .model = model }, diag));
}

/// A local model setting for display: the catalog name, or the file's name.
fn localModelName(model: []const u8) []const u8 {
    if (llm_models.find(model)) |e| return e.name;
    const base = std.fs.path.basename(if (std.mem.startsWith(u8, model, "file:")) model["file:".len..] else model);
    return if (std.ascii.endsWithIgnoreCase(base, ".gguf")) base[0 .. base.len - ".gguf".len] else base;
}

// ---- the link summarizer ---------------------------------------------------------------

/// The "Summarize link" flow (src/web_page.zig): what gets reported to the
/// summary window. `markdown` is everything streamed so far — a page that
/// (re)opens mid-flow reads it here instead of the events it missed.
pub const SummaryState = struct {
    /// "fetching", "reading", "writing", "ready" or "error".
    state: []const u8 = "",
    /// The link (before fetching) or the page's title (after).
    title: []const u8 = "",
    /// The page's readable size: what the summary works from.
    chars: usize = 0,
    /// The failure's phrase (state "error").
    message: []const u8 = "",
    markdown: []const u8 = "",
};

var summary_mutex: std.Io.Mutex = .init;
var link_summary: SummaryState = .{};
var summary_markdown: std.ArrayList(u8) = .empty;

fn summarySet(state: []const u8, title: []const u8, chars: usize, message: []const u8) void {
    summary_mutex.lockUncancelable(io);
    defer summary_mutex.unlock(io);
    link_summary = .{ .state = state, .title = title, .chars = chars, .message = message, .markdown = summary_markdown.items };
    // The live update: the accumulating markdown travels separately.
    App.emitTo("summary", "ghostpen://summary-status", .{
        .state = link_summary.state,
        .title = link_summary.title,
        .chars = link_summary.chars,
        .message = link_summary.message,
    }) catch {};
}

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

pub const AiProgress = struct {
    /// "loading" (the built-in model into memory), "reading" (the prompt),
    /// "writing" (the answer) or "waiting" (a connected service).
    stage: []const u8,
    model: []const u8,
    tokens: u32 = 0,
    tok_s: f32 = 0,
};

/// A menu action's completion, telling the menu how it goes
/// (ghostpen://ai-progress). The built-in model streams, so the tokens are
/// counted as they come; a connected service is one request.
fn completeWithProgress(arena: std.mem.Allocator, req: ai.Request) ![]const u8 {
    const local = req.profile.isLocal();
    const model = if (local) localModelName(req.profile.model) else req.profile.name;
    const first: []const u8 = if (!local) "waiting" else if (local_llm.loaded()) "reading" else "loading";
    App.emitTo("main", "ghostpen://ai-progress", AiProgress{ .stage = first, .model = model }) catch {};
    if (!local) return complete(arena, req);

    const Counter = struct {
        model: []const u8,
        start: std.Io.Timestamp,
        first_token: ?std.Io.Timestamp = null,
        tokens: u32 = 0,
        last_ms: i64 = -1000,

        fn chunk(c: *@This(), _: []const u8) void {
            const now = std.Io.Clock.awake.now(io);
            if (c.first_token == null) c.first_token = now;
            c.tokens += 1;
            const ms = c.start.durationTo(now).toMilliseconds();
            if (ms - c.last_ms < 120) return; // a few updates a second
            c.last_ms = ms;
            const writing_ms = c.first_token.?.durationTo(now).toMilliseconds();
            const tok_s: f32 = if (writing_ms > 0) @as(f32, @floatFromInt(c.tokens)) * 1000 / @as(f32, @floatFromInt(writing_ms)) else 0;
            App.emitTo("main", "ghostpen://ai-progress", AiProgress{ .stage = "writing", .model = c.model, .tokens = c.tokens, .tok_s = tok_s }) catch {};
        }
    };
    var counter: Counter = .{ .model = model, .start = std.Io.Clock.awake.now(io) };
    var diag: ai.Diag = .{};
    const out = ai.completeStream(io, gpa, arena, req, &counter, Counter.chunk, &diag) catch |err| {
        log.warn("AI request ({s} {s}) failed: {s}", .{ req.profile.name, req.profile.model, if (err == error.AiFailed) diag.message else @errorName(err) });
        return switch (err) {
            error.AiFailed => oriel.ipc.fail("{s}", .{diag.message}),
            else => err,
        };
    };
    const ms = counter.start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    log.info("AI request ({s} {s}): {d} chars in {d} ms", .{ req.profile.name, req.profile.model, out.len, ms });
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) log.warn("AI request returned only whitespace", .{});
    return out;
}

fn complete(arena: std.mem.Allocator, req: ai.Request) ![]const u8 {
    var diag: ai.Diag = .{};
    const start = std.Io.Clock.awake.now(io);
    const out = ai.complete(io, gpa, arena, req, &diag) catch |err| {
        log.warn("AI request ({s} {s}) failed: {s}", .{ req.profile.name, req.profile.model, if (err == error.AiFailed) diag.message else @errorName(err) });
        return switch (err) {
            error.AiFailed => oriel.ipc.fail("{s}", .{diag.message}),
            else => err,
        };
    };
    const ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    log.info("AI request ({s} {s}): {d} chars in {d} ms", .{ req.profile.name, req.profile.model, out.len, ms });
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) log.warn("AI request returned only whitespace", .{});
    return out;
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

/// Dictation's delivery: `output` on the clipboard, `label`'s window hidden
/// (focus goes back to the app underneath), pasted there, and the previous
/// clipboard back after the restore delay. False when synthetic input isn't
/// available: the text then stays on the clipboard.
pub fn pasteFromWindow(label: []const u8, output: []const u8, s: Settings) !bool {
    const prev = readClipboard();
    oriel.clipboard.writeText(output) catch |err| {
        prev.deinit();
        return err;
    };
    if (!useSynthetic(s)) {
        prev.deinit();
        return false;
    }
    const Hide = struct {
        fn run(l: []const u8) void {
            if (App.getWindow(l)) |w| w.hide();
        }
    };
    App.runOnMain(label, Hide.run);
    io.sleep(.fromMilliseconds(150), .awake) catch {};
    oriel.input.paste() catch |err| {
        log.warn("dictation: paste failed ({s}); the text is on the clipboard", .{@errorName(err)});
        prev.deinit();
        return false;
    };
    log.info("dictation: {d} chars pasted; the previous clipboard comes back in {d} ms", .{ output.len, s.restoreDelayMs });
    const t = std.Thread.spawn(.{}, restoreSnapshot, .{ prev, s.restoreDelayMs }) catch {
        prev.deinit();
        return true;
    };
    t.detach();
    return true;
}

/// The result stays in the menu (with Copy): nothing pasted, the clipboard
/// untouched, e.g. for text selected in something read-only.
fn showResult(output: []const u8) ProcessResult {
    log.info("deliver: {d} chars shown in the menu", .{output.len});
    return .{ .output = output, .pasted = false, .manual = false, .shown = true };
}

/// Put the result on the clipboard, paste it into the app underneath (hide
/// the menu first so it gets the keystroke), then restore what the
/// clipboard held before.
fn deliver(output: []const u8, s: Settings) !ProcessResult {
    oriel.clipboard.writeText(output) catch |err| {
        log.warn("deliver: writing the clipboard failed: {s}", .{@errorName(err)});
        return oriel.ipc.fail("Could not write the clipboard ({s}).", .{@errorName(err)});
    };
    if (!useSynthetic(s)) {
        log.info("deliver: {d} chars on the clipboard (manual mode: paste with Ctrl+V)", .{output.len});
        return .{ .output = output, .pasted = false, .manual = true };
    }

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
    log.info("deliver: {d} chars on the clipboard, Ctrl+V sent; the previous clipboard comes back in {d} ms", .{ output.len, s.restoreDelayMs });

    // Restore after the target app has read the clipboard. The snapshot is
    // taken now: a new trigger during the delay must not replace it.
    state_mutex.lockUncancelable(io);
    const snap = snapshot;
    snapshot = .empty;
    state_mutex.unlock(io);
    const t = std.Thread.spawn(.{}, restoreSnapshot, .{ snap, s.restoreDelayMs }) catch {
        snap.deinit();
        return .{ .output = output, .pasted = true, .manual = false };
    };
    t.detach();
    return .{ .output = output, .pasted = true, .manual = false };
}

fn restoreSnapshot(snap: Content, delay_ms: u64) void {
    defer snap.deinit();
    io.sleep(.fromMilliseconds(@intCast(@min(delay_ms, 60_000))), .awake) catch {};
    log.info("deliver: previous clipboard restored ({s})", .{@tagName(snap)});
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
    waitForInputProbe();

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

/// The clipboard now: text when there is some, else an image; empty when
/// neither (read errors are ignored: the trigger's snapshot is best effort).
fn readClipboard() Content {
    return readClipboardChecked() catch .empty;
}

/// Like `readClipboard`, but an error when the clipboard can't be read at all.
fn readClipboardChecked() !Content {
    var text_err: ?anyerror = null;
    if (oriel.clipboard.readText(gpa)) |text| {
        // An image offered as text (an X11 owner that serves its data for any
        // target, e.g. xclip) arrives as binary: that's not text.
        if (std.mem.trim(u8, text, " \t\r\n").len > 0 and isText(text)) return .{ .text = text };
        gpa.free(text);
    } else |err| text_err = err;
    if (oriel.clipboard.readImage(gpa)) |maybe| {
        if (maybe) |png| return .{ .image = png };
    } else |err| if (text_err != null) return err;
    return .empty;
}

/// Valid UTF-8 without control characters other than tab and line breaks
/// (binary data that GTK turned into "text" keeps its control bytes).
fn isText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |c| switch (c) {
        '\t', '\n', '\r' => {},
        0...8, 11, 12, 14...31, 127 => return false,
        else => {},
    };
    return true;
}

test isText {
    try std.testing.expect(isText("teh quick brown fox"));
    try std.testing.expect(isText("año · 日本"));
    try std.testing.expect(!isText("\x89PNG\r\n\x1a\n"));
    try std.testing.expect(!isText("a\x00b"));
    // What GTK makes of a PNG served as text.
    try std.testing.expect(!isText("\\89PNG\r\n\x1a\n"));
    try std.testing.expect(isText("line one\r\n\tindented"));
}

/// Show (and focus) a window by label, centering the menu.
pub fn showWindow(label: []const u8, center: bool) void {
    const w = App.ensureWindow(label) catch |err| return log.err("window {s}: {s}", .{ label, @errorName(err) });
    if (center) w.center();
    w.show();
    w.focus();
}

// ---- commands ----------------------------------------------------------------------------

pub const Commands = struct {
    pub const async_commands = .{
        "get_selection",           "extract_image_text",   "process_ai_action",     "process_ai_custom",
        "process_text",            "process_text_stream",  "fetch_models",          "captions_start",
        "captions_download_model", "dictation_start",      "captions_list_devices", "dictation_list_devices",
        "llm_models_status",       "llm_download_model",   "llm_delete_model",      "llm_unload",
        "menu_dismissed",          "update_check",         "update_install",        "whisper_models_status",
        "whisper_download_model",  "whisper_delete_model", "summarize_link",        "summary_state",
    };

    pub fn get_settings(arena: std.mem.Allocator) !Settings {
        return shared.get(io, arena);
    }

    pub fn save_settings(arena: std.mem.Allocator, args: struct { settings: Settings }) !void {
        shared.set(io, gpa, args.settings) catch |err| return oriel.ipc.fail("Could not save the settings ({s}).", .{@errorName(err)});
        // Switched to an endpoint (a local server may need the GPU memory):
        // the built-in model goes now, not after its idle timeout. Off the
        // main thread: unloading waits for an answer still being written.
        if (!args.settings.activeProfile().isLocal() and local_llm.loaded()) {
            if (std.Thread.spawn(.{}, local_llm.unload, .{io})) |t| t.detach() else |_| {}
        }
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

    /// The clipboard's text, when there is any (the summary window's link
    /// box prefills from it: the URL is usually just copied).
    pub fn clipboard_text(arena: std.mem.Allocator) ![]const u8 {
        const t = oriel.clipboard.readText(gpa) catch return "";
        defer gpa.free(t);
        return arena.dupe(u8, t);
    }

    pub fn get_status(arena: std.mem.Allocator) !Status {
        const s = try shared.get(io, arena);
        const p = s.activeProfile();
        return .{
            .session = sessionName(),
            .clipboard_backend = "oriel",
            .input_available = input_available.load(.acquire),
            .manual_mode = !useSynthetic(s),
            .active_profile = p.name,
            .active_model = if (p.isLocal()) localModelName(p.model) else p.model,
        };
    }

    /// The clipboard (after the trigger's copy): text first, then an image.
    pub fn get_selection(arena: std.mem.Allocator) !SelectionInfo {
        const content = readClipboardChecked() catch |err| return oriel.ipc.fail("Could not read the clipboard ({s}).", .{@errorName(err)});
        errdefer content.deinit();
        const info: SelectionInfo = switch (content) {
            .empty => .{ .kind = "empty" },
            .text => |t| .{ .kind = "text", .text = try arena.dupe(u8, t) },
            .image => |png| blk: {
                const size = image.pngSize(png) orelse image.Size{ .width = 0, .height = 0 };
                const thumb = image.fitWithin(gpa, png, 512) catch |err| return oriel.ipc.fail("Could not read the image ({s}).", .{@errorName(err)});
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

    /// `show`: keep the result in the menu (Shift+action) instead of pasting
    /// it over the selection; also when Settings say "show".
    pub fn process_ai_action(arena: std.mem.Allocator, args: struct { action: []const u8, targetLang: ?[]const u8 = null, level: ?[]const u8 = null, show: bool = false }) !ProcessResult {
        try acquireBusy();
        defer busy.store(false, .release);
        const s = try shared.get(io, arena);
        const text = try selectionText(arena);
        log.info("action {s}{s}{s} ({s}) on {d} chars", .{ args.action, if (args.targetLang != null) " → " else "", args.targetLang orelse "", args.level orelse "balanced", text.len });
        const r = try resolveAction(arena, s, args.action, args.targetLang, parseLevel(args.level));
        const output = try completeWithProgress(arena, .{ .profile = r.profile, .system = r.system, .user = .{ .text = text } });
        if (args.show or s.showResults()) return showResult(output);
        return deliver(output, s);
    }

    pub fn process_ai_custom(arena: std.mem.Allocator, args: struct { instruction: []const u8, show: bool = false }) !ProcessResult {
        try acquireBusy();
        defer busy.store(false, .release);
        const s = try shared.get(io, arena);
        const text = try selectionText(arena);
        const system = try ai.instructionPrompt(arena, args.instruction);
        const output = try completeWithProgress(arena, .{ .profile = s.activeProfile(), .system = system, .user = .{ .text = text } });
        if (args.show or s.showResults()) return showResult(output);
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

    // ---- Summarize a link ----

    /// The summary window's page asks for the flow's state when it loads:
    /// its listeners attach after the first event was broadcast, so here is
    /// what happened so far (the stage, the page title and the markdown).
    pub fn summary_state(arena: std.mem.Allocator) !SummaryState {
        summary_mutex.lockUncancelable(io);
        defer summary_mutex.unlock(io);
        var out = link_summary;
        out.markdown = arena.dupe(u8, summary_markdown.items) catch "";
        return out;
    }

    /// Read a URL (menu selection), summarize its document with the active
    /// profile and stream the answer to the summary window as Markdown.
    /// Failures of the page or the model report to the window, not the menu
    /// (the menu is already behind the window the user is looking at).
    pub fn summarize_link(arena: std.mem.Allocator, args: struct { url: []const u8, level: ?[]const u8 = null }) !void {
        try acquireBusy();
        defer busy.store(false, .release);
        const url = std.mem.trim(u8, args.url, " \t\r\n");
        if (url.len == 0) return oriel.ipc.fail("No link to summarize.", .{});

        {
            summary_mutex.lockUncancelable(io);
            defer summary_mutex.unlock(io);
            link_summary = .{ .state = "fetching", .title = url };
            summary_markdown.clearRetainingCapacity();
        }
        showWindow("summary", true);

        var diag: web_page.Diag = .{};
        const page = web_page.read(io, gpa, arena, url, &diag) catch |err| blk: {
            const msg: []const u8 = switch (err) {
                error.AiFailed => diag.message,
                error.OutOfMemory => "Out of memory reading the page.",
            };
            summarySet("error", url, 0, msg);
            log.warn("summarize: {s}: {s}", .{ url, msg });
            break :blk null;
        };
        const pd = page orelse return;
        summarySet("reading", pd.title, pd.text.len, "");
        log.info("summarize: {s}: {s} ({d} chars)", .{ url, pd.title, pd.text.len });

        const Emit = struct {
            fn chunk(_: void, delta: []const u8) void {
                summary_mutex.lockUncancelable(io);
                summary_markdown.appendSlice(gpa, delta) catch {};
                link_summary.markdown = summary_markdown.items;
                summary_mutex.unlock(io);
                App.emitTo("summary", "ghostpen://summary-chunk", delta) catch {};
            }
        };
        summarySet("writing", pd.title, pd.text.len, "");
        var ai_diag: ai.Diag = .{};
        _ = ai.completeStream(io, gpa, arena, .{
            .profile = (try shared.get(io, arena)).activeProfile(),
            .system = try web_page.summaryPrompt(arena, web_page.parseLevel(args.level)),
            .user = .{ .text = try pd.prompt(arena) },
        }, {}, Emit.chunk, &ai_diag) catch |err| {
            const msg: []const u8 = if (err == error.AiFailed) ai_diag.message else @errorName(err);
            summarySet("error", pd.title, pd.text.len, msg);
            log.warn("summarize: the AI request failed: {s}", .{msg});
            return;
        };
        summarySet("ready", pd.title, pd.text.len, "");
    }

    // ---- built-in models (Settings → Built-in models) ----

    pub const LlmStatus = struct {
        status: llm_models.Status,
        downloading: bool,
        loaded: bool,
    };

    pub fn llm_models_status(arena: std.mem.Allocator) !LlmStatus {
        const d = try llmDirs(arena);
        const st = try llm_models.status(io, arena, d);
        // The context each model was trained for (metadata only): what the
        // context window may be raised to.
        for (st.models) |*m| if (m.path.len > 0) {
            m.ctx_max = llm_helper.trainedCtx(io, m.path);
        };
        for (st.others) |*o| {
            o.ctx_max = llm_helper.trainedCtx(io, o.path);
        }
        return .{
            .status = st,
            .downloading = llm_models.isDownloading(),
            .loaded = local_llm.loaded(),
        };
    }

    /// Progress goes to the Settings window as `ghostpen://llm-download`.
    pub fn llm_download_model(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const d = try llmDirs(arena);
        const Emit = struct {
            fn progress(_: void, p: llm_models.Progress) void {
                App.emitTo("settings", "ghostpen://llm-download", p) catch {};
            }
        };
        var status: std.http.Status = .ok;
        _ = llm_models.download(io, gpa, arena, d, args.id, {}, Emit.progress, &status) catch |err| {
            // Another download is running: its progress bar stays as it is.
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

    pub fn llm_cancel_download(_: std.mem.Allocator) void {
        llm_models.cancelDownload();
    }

    pub fn llm_delete_model(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        local_llm.unload(io); // it may be the loaded one
        const d = try llmDirs(arena);
        llm_models.remove(io, arena, d, args.id) catch |err| return if (err == error.Busy)
            oriel.ipc.fail("Wait for the download to finish (or pause it) first.", .{})
        else
            oriel.ipc.fail("Could not delete the model ({s}).", .{@errorName(err)});
    }

    /// The menu closed without pasting (Escape, Close, a cancelled or failed
    /// action): put back what the clipboard held before the trigger's copy,
    /// unless the clipboard changed since (the user copied something else).
    pub fn menu_dismissed(_: std.mem.Allocator) void {
        state_mutex.lockUncancelable(io);
        const snap = snapshot;
        snapshot = .empty;
        const copied: ?[]u8 = switch (current_input) {
            .text => |t| gpa.dupe(u8, t) catch null,
            else => null,
        };
        state_mutex.unlock(io);
        defer if (copied) |c| gpa.free(c);
        if (snap == .empty) return;
        const still_selection = blk: {
            const now = oriel.clipboard.readText(gpa) catch break :blk false;
            defer gpa.free(now);
            // An image selection has no text to compare: the clipboard then holds no text.
            break :blk if (copied) |c| std.mem.eql(u8, now, c) else std.mem.trim(u8, now, " \t\r\n").len == 0;
        };
        if (!still_selection) {
            snap.deinit();
            return;
        }
        restoreSnapshot(snap, 0);
    }

    /// Stop the running AI request, when it runs on the built-in model (it
    /// returns what it has; an endpoint request runs to its timeout).
    pub fn cancel_ai(_: std.mem.Allocator) void {
        local_llm.cancel(io);
    }

    /// Free the built-in model's memory now.
    pub fn llm_unload(_: std.mem.Allocator) void {
        local_llm.unload(io);
    }

    // Updates live in updates.zig.
    pub const app_info = updates.Commands.app_info;
    pub const update_check = updates.Commands.update_check;
    pub const update_install = updates.Commands.update_install;
    pub const update_restart = updates.Commands.update_restart;

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
    pub const whisper_models_status = captions.Commands.whisper_models_status;
    pub const whisper_download_model = captions.Commands.whisper_download_model;
    pub const whisper_cancel_download = captions.Commands.whisper_cancel_download;
    pub const whisper_delete_model = captions.Commands.whisper_delete_model;
    pub const dictation_list_devices = dictation.Commands.dictation_list_devices;
    pub const dictation_status = dictation.Commands.dictation_status;
    pub const dictation_start = dictation.Commands.dictation_start;
    pub const dictation_stop = dictation.Commands.dictation_stop;
    pub const dictation_cancel = dictation.Commands.dictation_cancel;
    pub const dictation_set_language = dictation.Commands.dictation_set_language;
    pub const dictation_set_proofread = dictation.Commands.dictation_set_proofread;
};

/// The working selection; when the menu hasn't read one, the clipboard
/// (as the Tauri app does). Runs on a worker thread (clipboard reads block).
fn selectionText(arena: std.mem.Allocator) ![]const u8 {
    {
        state_mutex.lockUncancelable(io);
        defer state_mutex.unlock(io);
        switch (current_input) {
            .text => |t| return arena.dupe(u8, t),
            .image => return oriel.ipc.fail("An image is selected: extract its text first.", .{}),
            .empty => {},
        }
    }
    const text = oriel.clipboard.readText(gpa) catch |err| return oriel.ipc.fail("Could not read the clipboard ({s}).", .{@errorName(err)});
    defer gpa.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return oriel.ipc.fail("Nothing selected: highlight some text, then trigger GhostPen.", .{});
    return arena.dupe(u8, text);
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
    } else if (eql(u8, id, "summary")) {
        showWindow("summary", false);
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
        } else if (eql(u8, a, "--summary")) {
            showWindow("summary", false);
        }
    }
}

var launch_args: []const []const u8 = &.{};

fn setup() !void {
    shared.load(io, gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try shared.get(io, arena.allocator());

    // The other windows: declared now, created hidden the first time they're
    // shown (each is a web view: a WebKit process and a page load), hidden
    // again when closed.
    const windows = [_]App.WindowOptions{
        .{ .label = "settings", .title = "GhostPen Settings", .url = "index.html#/settings", .width = 540, .height = 680, .visible = false, .hide_on_close = true },
        .{ .label = "playground", .title = "GhostPen Playground", .url = "index.html#/playground", .width = 640, .height = 620, .visible = false, .hide_on_close = true },
        .{ .label = "summary", .title = "GhostPen Summary", .url = "index.html#/summary", .width = 780, .height = 850, .visible = false, .hide_on_close = true },
        .{ .label = "dictation", .title = "GhostPen Dictation", .url = "index.html#/dictation", .width = 520, .height = 200, .resizable = false, .decorations = false, .visible = false, .transparent = true, .always_on_top = true, .skip_taskbar = true, .placement = .{ .anchor = .bottom, .margin = 64 }, .hide_on_close = true },
        .{ .label = "captions", .title = "GhostPen Captions", .url = "index.html#/captions", .width = 900, .height = 170, .decorations = false, .visible = false, .transparent = true, .always_on_top = true, .skip_taskbar = true, .placement = .{ .anchor = .bottom, .margin = 64 }, .hide_on_close = true, .focus_on_show = false },
    };
    for (windows) |w| App.registerWindow(w) catch |err| log.err("window {s}: {s}", .{ w.label, @errorName(err) });

    tray = oriel.tray.Tray.create(gpa, .{
        .id = settings_mod.app_id,
        .title = "GhostPen",
        .tooltip = "GhostPen",
        .icon = .{ .png = app.icon_bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show menu" } },
            .{ .item = .{ .id = "dictate", .label = "Dictation" } },
            .{ .item = .{ .id = "captions", .label = "Captions" } },
            .{ .item = .{ .id = "summary", .label = "Summarize a link" } },
            .{ .item = .{ .id = "playground", .label = "Playground" } },
            .{ .item = .{ .id = "settings", .label = "Settings" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit" } },
        },
        .on_menu = onTrayMenu,
        .on_activate = triggerMenuFlow,
    }) catch |err| blk: {
        log.warn("no tray icon ({s}); use the hotkeys or `ghostpen --trigger`", .{@errorName(err)});
        break :blk null;
    };

    const failed = registerHotkeys(arena.allocator(), s);
    if (failed.len > 0) log.warn("hotkeys not registered: {s} (bind `ghostpen --trigger` in your desktop instead)", .{failed});

    // macOS gates synthetic keystrokes behind Accessibility: ask once (the
    // prompt lists GhostPen; elsewhere this is already granted).
    switch (oriel.permissions.status(.accessibility)) {
        .granted => {},
        .denied => log.info("Accessibility is off for GhostPen: synthetic copy/paste won't work (System Settings → Privacy & Security → Accessibility)", .{}),
        .prompt, .unknown => _ = oriel.permissions.request(.accessibility),
    }

    // Synthetic input available? (Probed off the UI thread: it may talk to the compositor.)
    if (std.Thread.spawn(.{}, probeInput, .{})) |t| t.detach() else |_| {}

    captions.init();
    dictation.init();
    // The model service (chat, vision, embeddings, transcription) for other
    // local apps: stt_server.zig, model_server.zig.
    @import("stt_server.zig").maybeStart(io, environ_map);
    updates.init(environ_map);
    handleArgs(launch_args);
}

fn probeInput() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    defer input_probed.store(true, .release);
    const check = oriel.input.check(arena.allocator(), .{ .io = io, .icon_png = app.icon_bytes }) catch return;
    input_available.store(check.ok, .release);
    if (!check.ok) log.info("synthetic input unavailable ({s}): manual-copy mode", .{check.detail});
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The built-in model runner (started by local_llm.zig): no GUI.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--llm-helper"))
        return @import("llm_helper.zig").main(io, gpa, args[2..]);
    // The whisper runner (started by models.zig): no GUI.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--whisper-helper"))
        return @import("whisper_helper.zig").main(io, gpa, args[2..]);
    environ_map = init.environ_map;
    // The LLM runner remembers its last successful split per model+settings
    // in GhostPen's config (~/.config/ghostpen/llm-plans.json): a model swap
    // doesn't re-run the whole plan ladder on every load.
    local_llm.plan_path = llm_models.configFile(init.arena.allocator(), init.environ_map, "llm-plans.json");
    self_exe = std.process.executablePathAlloc(io, init.arena.allocator()) catch null;
    @import("models.zig").helper_exe = self_exe;
    ai.local_resolver = &resolveLocal;
    // Whisper models other apps (GhostReel) downloaded are reused.
    if (llmDirs(init.arena.allocator())) |d| {
        @import("models.zig").search_dirs = d.others;
    } else |_| {}
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print(
                \\Usage: ghostpen [--trigger | --voice-input | --captions | --settings | --playground | --tray]
                \\
                \\A running GhostPen receives these flags from later launches, so a
                \\desktop keybinding can run e.g. `ghostpen --trigger`.
                \\
            , .{});
            return 0;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("ghostpen {s}\n", .{@import("ghostpen_build").version});
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

    // The model service's discovery file goes with the app (a stale one is
    // also ignored: its pid is gone).
    defer @import("model_server.zig").removeDiscovery(io, environ_map);
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
        // The page paints only its rounded panel (.menu): the corners show
        // what's behind the window.
        .transparent = true,
        .show_main_window = false,
        .on_close = .hide,
        .assets = app.assets,
        .dev = app.dev,
        .icon = app.icon_bytes,
        .permissions = app.permissions,
        .setup = &setup,
        .on_second_instance = &handleArgs,
        .on_session_end = &sessionEnd,
    });
}

/// Windows logoff or shutdown: the process can be killed before `oriel.main`
/// returns, so the deferred cleanup above runs here too.
fn sessionEnd() void {
    @import("model_server.zig").removeDiscovery(io, environ_map);
}
