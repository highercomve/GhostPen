//! GhostPen settings: the same camelCase JSON schema as the Tauri app.
//! Pure data and parsing (shared with ghostpen-cli); `store.zig` keeps them
//! in an Oriel store.

const std = @import("std");

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    /// "openai" (an OpenAI-compatible endpoint) or "local" (built-in: GhostPen runs
    /// the model itself with its embedded llama.cpp; `model` is a catalog id or `file:<path>`).
    provider: []const u8 = "openai",
    baseUrl: []const u8 = "",
    apiKey: []const u8 = "",
    model: []const u8,
    temperature: f64 = 0.2,

    pub fn isLocal(self: Profile) bool {
        return std.mem.eql(u8, self.provider, "local");
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
    language: []const u8 = "auto",
    proofread: bool = true,
    device: []const u8 = "",
    /// Paste the text at the cursor when finished (off: copy only, to review first).
    paste: bool = true,
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
    localLlm: LocalLlm = .{},
    /// The model & speech service's address and port.
    server: Server = .{},
    /// Check for updates in the background, and install them where
    /// GhostPen can (Settings → About & updates).
    autoUpdate: bool = true,

    /// The active profile, or the first one, or the built-in default.
    pub fn showResults(self: Settings) bool {
        return std.mem.eql(u8, self.afterAction, "show");
    }

    pub fn activeProfile(self: Settings) Profile {
        for (self.profiles) |p| if (std.mem.eql(u8, p.id, self.activeProfileId)) return p;
        return if (self.profiles.len > 0) self.profiles[0] else default_profile;
    }
};

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
    return std.json.parseFromValueLeaky(Settings, arena, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
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
