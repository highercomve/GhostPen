//! GhostPen settings: the same camelCase JSON schema as the Tauri app.
//! Pure data and parsing (shared with ghostpen-cli); `store.zig` keeps them
//! in an Oriel store.

const std = @import("std");

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    /// "openai" (an OpenAI-compatible endpoint), "local" (built-in: GhostPen runs
    /// the model itself with its embedded llama.cpp; `model` is a catalog id or `file:<path>`),
    /// or "system" (the phone's own model: Gemini Nano on Android; `model` unused).
    provider: []const u8 = "openai",
    baseUrl: []const u8 = "",
    apiKey: []const u8 = "",
    model: []const u8,
    temperature: f64 = 0.2,

    pub fn isLocal(self: Profile) bool {
        return std.mem.eql(u8, self.provider, "local");
    }

    pub fn isSystem(self: Profile) bool {
        return std.mem.eql(u8, self.provider, "system");
    }
};

/// The built-in runner ("Built-in" profiles: GhostPen runs the model itself).
pub const LocalLlm = struct {
    /// Context window in tokens (prompt + answer).
    ctxTokens: u32 = 8192,
    /// Offload to the GPU when there is one.
    gpu: bool = true,
    /// MoE models: the share of the expert weights kept in system RAM
    /// (llama.cpp's --n-cpu-moe, as a percentage of the blocks); 0 = all
    /// experts on the GPU, 100 = every expert in RAM, attention on the GPU.
    moePct: u8 = 0,
    /// Unload the model after this many minutes without use (0 = never).
    idleMinutes: u32 = 10,
};

pub const CustomAction = struct {
    id: []const u8,
    label: []const u8,
    prompt: []const u8,
    /// "" = the active profile's model.
    model: []const u8 = "",
};

pub const Ocr = struct {
    maxDimension: u32 = 1024,
    systemPrompt: []const u8 = "",
    modelOverride: []const u8 = "",
};

/// The model & speech service (stt_server.zig + model_server.zig): other
/// local apps' OpenAI-compatible endpoint for the built-in chat models and
/// the transcription models.
pub const Server = struct {
    /// The address it listens on. `0.0.0.0` = reachable from the network
    /// (no authentication: a trusted network only).
    host: []const u8 = "127.0.0.1",
    port: u16 = 8771,
    /// Context window (tokens) for chat requests from other apps; 0 = the
    /// built-in model's setting (`LocalLlm.ctxTokens`). A request can still
    /// ask for more (`options.num_ctx`); the runner caps it at the model's
    /// trained maximum.
    ctxTokens: u32 = 0,
};

pub const Captions = struct {
    /// A floating bar over other windows (off, in single-window mode: a
    /// page of the app window).
    float: bool = true,
    model: []const u8 = "base",
    language: []const u8 = "auto",
    whisperTranslate: bool = false,
    aiTranslate: bool = false,
    targetLang: []const u8 = "English",
    chunkSeconds: f64 = 5.0,
    device: []const u8 = "",
    fontSize: u32 = 28,
};

pub const Dictation = struct {
    /// A floating panel over other windows (off, in single-window mode: a
    /// page of the app window).
    float: bool = true,
    language: []const u8 = "auto",
    proofread: bool = true,
    device: []const u8 = "",
    /// "auto" (Android: the phone's speech recognition when it has one, else
    /// whisper; elsewhere whisper), "whisper", or "system" (Android's).
    engine: []const u8 = "auto",
    /// Paste the text at the cursor when finished (off: copy only, to review first).
    paste: bool = true,
};

/// Meeting mode (MEETINGS.md): captions that record, keep and proofread.
pub const Meetings = struct {
    /// Captions start in meeting mode (the overlay's toggle changes it).
    enabled: bool = false,
    /// Where meetings are saved ("" = Documents/GhostPen/Meetings).
    dir: []const u8 = "",
    /// Record the microphone too (`dictation.device`), as "Me".
    mic: bool = true,
    /// Proofread the transcript with the active profile when saving.
    proofread: bool = true,
    /// Summarize it too when saving (else from the Meetings window).
    summary: bool = false,
    /// Tell the others apart by voice when saving (a speaker model, downloaded
    /// on first use), and name the known voices.
    speakers: bool = true,
    /// The speaker model (oriel.speakers catalog id; "" = the default).
    speakerModel: []const u8 = "",
    /// How many people besides you, when known (0 = find out).
    expectedSpeakers: u32 = 0,
    /// Label the speakers live in the captions too (less accurate than on save).
    liveSpeakers: bool = true,
};

pub const Settings = struct {
    hotkey: []const u8 = "Ctrl+Shift+A",
    dictationHotkey: []const u8 = "Ctrl+Shift+D",
    captionsHotkey: []const u8 = "Ctrl+Shift+L",
    activeProfileId: []const u8 = "ollama-local",
    profiles: []const Profile = &.{default_profile},
    forceSynthetic: bool = false,
    restoreDelayMs: u64 = 300,
    /// After a menu action: "paste" (over the selection) or "show" (in the
    /// menu, with Copy: for text selected in something read-only).
    afterAction: []const u8 = "paste",
    customActions: []const CustomAction = &.{},
    ocr: Ocr = .{},
    captions: Captions = .{},
    dictation: Dictation = .{},
    meetings: Meetings = .{},
    localLlm: LocalLlm = .{},
    /// The model & speech service's address and port.
    server: Server = .{},
    /// Check for updates in the background, and install them where
    /// GhostPen can (Settings → About & updates).
    autoUpdate: bool = true,
    /// "windows": a window per page (the menu, Settings, Playground, …);
    /// "single": one app window with the pages in a sidebar. Read at start
    /// (a change applies on the next one); Android is always "single".
    interfaceMode: []const u8 = "windows",
    /// Who reads text aloud: "kokoro" (the voices downloaded in Settings →
    /// Voices), "system" (the device's own: Android's TextToSpeech), or
    /// "auto" (Android: the device's until a Kokoro model is downloaded).
    voiceEngine: []const u8 = "auto",

    /// The active profile, or the first one, or the built-in default.
    pub fn showResults(self: Settings) bool {
        return std.mem.eql(u8, self.afterAction, "show");
    }

    pub fn singleWindow(self: Settings) bool {
        return std.mem.eql(u8, self.interfaceMode, "single");
    }

    pub fn activeProfile(self: Settings) Profile {
        for (self.profiles) |p| if (std.mem.eql(u8, p.id, self.activeProfileId)) return p;
        return if (self.profiles.len > 0) self.profiles[0] else default_profile;
    }

    /// Bring the numbers into their sane ranges (the page's controls stay
    /// within them, but the file can be edited by hand and the page is not
    /// trusted). A profile list that needs fixing is copied into `arena`.
    pub fn clamp(self: *Settings, arena: std.mem.Allocator) !void {
        const c = std.math.clamp;
        self.ocr.maxDimension = c(self.ocr.maxDimension, 64, 8192);
        self.localLlm.ctxTokens = c(self.localLlm.ctxTokens, min_ctx, max_ctx);
        self.localLlm.moePct = @min(self.localLlm.moePct, 100);
        self.localLlm.idleMinutes = @min(self.localLlm.idleMinutes, 24 * 60);
        // 0 = the built-in model's setting.
        if (self.server.ctxTokens != 0) self.server.ctxTokens = c(self.server.ctxTokens, min_ctx, max_ctx);
        if (self.server.port == 0) self.server.port = (Server{}).port;
        self.captions.chunkSeconds = finiteIn(self.captions.chunkSeconds, 1.0, 60.0, (Captions{}).chunkSeconds);
        self.captions.fontSize = c(self.captions.fontSize, 8, 200);
        self.restoreDelayMs = @min(self.restoreDelayMs, 10_000);
        for (self.profiles, 0..) |p, i| {
            if (finiteIn(p.temperature, 0.0, 2.0, 0.2) == p.temperature) continue;
            const copy = try arena.dupe(Profile, self.profiles);
            for (copy[i..]) |*q| q.temperature = finiteIn(q.temperature, 0.0, 2.0, 0.2);
            self.profiles = copy;
            break;
        }
    }
};

const min_ctx = 512;
const max_ctx = 1024 * 1024;

/// `v` within `[lo, hi]`; `fallback` when it isn't a number.
fn finiteIn(v: f64, lo: f64, hi: f64, fallback: f64) f64 {
    if (!std.math.isFinite(v)) return fallback;
    return std.math.clamp(v, lo, hi);
}

pub const default_profile: Profile = .{
    .id = "ollama-local",
    .name = "Ollama (local)",
    .baseUrl = "http://localhost:11434/v1",
    .model = "gemma4:e4b",
};

pub const app_id = "dev.ghostpen.Oriel";

/// Parse settings JSON (a bare object, or Tauri's store envelope
/// `{"settings": {...}}`); missing fields take their defaults.
pub fn parse(arena: std.mem.Allocator, value: std.json.Value) !Settings {
    const v = if (value == .object) (value.object.get("settings") orelse value) else value;
    var s = try std.json.parseFromValueLeaky(Settings, arena, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try s.clamp(arena);
    return s;
}

/// A deep copy through JSON (settings are small; this keeps it obviously right).
pub fn clone(arena: std.mem.Allocator, s: Settings) !Settings {
    const json = try std.json.Stringify.valueAlloc(arena, s, .{});
    return std.json.parseFromSliceLeaky(Settings, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "parse: defaults, envelope, unknown fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    const d = try parse(a, empty);
    try std.testing.expectEqualStrings("Ctrl+Shift+A", d.hotkey);
    try std.testing.expectEqualStrings("gemma4:e4b", d.activeProfile().model);

    const env = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"settings":{"hotkey":"Ctrl+Alt+G","activeProfileId":"groq","futureField":1,
        \\ "profiles":[{"id":"groq","name":"Groq","baseUrl":"https://api.groq.com/openai/v1","apiKey":"k","model":"llama","temperature":0.5}],
        \\ "captions":{"model":"small"}}}
    , .{});
    const s = try parse(a, env);
    try std.testing.expectEqualStrings("Ctrl+Alt+G", s.hotkey);
    try std.testing.expectEqualStrings("llama", s.activeProfile().model);
    try std.testing.expectEqualStrings("small", s.captions.model);
    try std.testing.expectEqual(@as(f64, 5.0), s.captions.chunkSeconds);
    try std.testing.expectEqual(@as(u64, 300), s.restoreDelayMs);

    const copy = try clone(a, s);
    try std.testing.expectEqualStrings(s.profiles[0].apiKey, copy.profiles[0].apiKey);
    try std.testing.expect(!s.activeProfile().isLocal());
    try std.testing.expectEqual(@as(u32, 8192), s.localLlm.ctxTokens);

    const local = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"activeProfileId":"here","profiles":[{"id":"here","name":"Built-in (GhostPen)","provider":"local","model":"gemma-4-e4b-it"}],
        \\ "localLlm":{"ctxTokens":4096}}
    , .{});
    const l = try parse(a, local);
    try std.testing.expect(l.activeProfile().isLocal());
    try std.testing.expectEqual(@as(u32, 4096), l.localLlm.ctxTokens);
}

test "clamp: out-of-range numbers come back into range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"ocr":{"maxDimension":0},"localLlm":{"ctxTokens":4000000000,"moePct":250,"idleMinutes":999999},
        \\ "server":{"ctxTokens":1,"port":0},"captions":{"chunkSeconds":0.01,"fontSize":4000},"restoreDelayMs":99999999,
        \\ "profiles":[{"id":"a","name":"A","model":"m","temperature":7.5},{"id":"b","name":"B","model":"m","temperature":0.7}]}
    , .{});
    const s = try parse(a, v);
    try std.testing.expectEqual(@as(u32, 64), s.ocr.maxDimension);
    try std.testing.expectEqual(@as(u32, max_ctx), s.localLlm.ctxTokens);
    try std.testing.expectEqual(@as(u8, 100), s.localLlm.moePct);
    try std.testing.expectEqual(@as(u32, 24 * 60), s.localLlm.idleMinutes);
    try std.testing.expectEqual(@as(u32, min_ctx), s.server.ctxTokens);
    try std.testing.expectEqual(@as(u16, 8771), s.server.port);
    try std.testing.expectEqual(@as(f64, 1.0), s.captions.chunkSeconds);
    try std.testing.expectEqual(@as(u32, 200), s.captions.fontSize);
    try std.testing.expectEqual(@as(u64, 10_000), s.restoreDelayMs);
    try std.testing.expectEqual(@as(f64, 2.0), s.profiles[0].temperature);
    try std.testing.expectEqual(@as(f64, 0.7), s.profiles[1].temperature);

    // In range: left alone (and the default profile list isn't copied).
    var d: Settings = .{};
    try d.clamp(a);
    try std.testing.expectEqual(@as(u32, 1024), d.ocr.maxDimension);
    try std.testing.expectEqual(@as(u32, 0), d.server.ctxTokens);
    try std.testing.expect(d.profiles.ptr == (Settings{}).profiles.ptr);

    var nan: Settings = .{};
    nan.captions.chunkSeconds = std.math.nan(f64);
    try nan.clamp(a);
    try std.testing.expectEqual(@as(f64, 5.0), nan.captions.chunkSeconds);
}
