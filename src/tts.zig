//! The built-in voice: Kokoro-82M offline text-to-speech through Oriel's
//! `oriel.tts` (kokoro.cpp + espeak-ng compiled in with `-Dkokoro`, the
//! model on the GPU where ggml finds one, streaming playback, Markdown read
//! as prose, the language guessed from the text).
//!
//! What GhostPen adds on top: the models live in `<data dir>/GhostPen/tts`
//! (downloads from older builds are kept), the menu's translate targets
//! ("French") map to espeak languages, a first reading downloads the model
//! and the voice for its language before it speaks, and readings run on a
//! worker so `tts_speak` returns at once (the UI follows "tts:state").
//! One reading at a time: a newer `speak` or `stop` cancels the running one.
//! The CLI (`--say`) uses `say` directly.

const std = @import("std");
const oriel = @import("oriel");
const llm_models = @import("llm_models.zig");

const tts = oriel.tts;
const log = std.log.scoped(.ghostpen_tts);

pub const State = tts.State;

// ---- languages and voices ------------------------------------------------------------------

/// "French" → "fr" over the languages the translate menu offers (the exact
/// names `api.ts`'s TRANSLATE_LANGUAGES carries); null when not in the list.
pub fn espeakLanguageFor(target: []const u8) ?[]const u8 {
    const pairs = [_]struct { text: []const u8, lang: []const u8 }{
        .{ .text = "English", .lang = "en-us" },
        .{ .text = "Spanish", .lang = "es" },
        .{ .text = "French", .lang = "fr" },
        .{ .text = "Portuguese", .lang = "pt-br" },
        .{ .text = "Italian", .lang = "it" },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(p.text, target)) return p.lang;
    return null;
}

/// The espeak language to read `text` in: `lang` as given (an espeak
/// language or a translate target), or guessed from the text when empty.
pub fn languageFor(text: []const u8, lang: []const u8) []const u8 {
    if (lang.len == 0 or std.mem.eql(u8, lang, "auto")) return tts.guessLanguage(text);
    return espeakLanguageFor(lang) orelse lang;
}

/// The voice for `lang`: one of that language already on the device, else
/// the catalog's first for it (downloaded by the reading), else US English.
pub fn voiceFor(lang: []const u8) []const u8 {
    for (&tts.voices) |*v| if (std.mem.eql(u8, v.lang, lang) and tts.voicePresent(v)) return v.id;
    for (&tts.voices) |*v| if (std.mem.eql(u8, v.lang, lang)) return v.id;
    return tts.voices[0].id;
}

// ---- files ---------------------------------------------------------------------------------

/// `<data dir>/GhostPen/tts` (next to the chat models); null when the app has
/// no data dir at all.
pub fn modelsDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    const own = llm_models.ownDir(arena, env) orelse return null;
    const app_root = std.fs.path.dirname(own) orelse return null;
    return std.fs.path.join(arena, &.{ app_root, "tts" }) catch null;
}

/// Early builds kept the voice in `<data dir>/ghostpen/tts`: move what the
/// catalog knows from there (same file names) unless it is here already.
fn adoptLegacy(arena: std.mem.Allocator, dir: []const u8, io: std.Io) void {
    const app_root = std.fs.path.dirname(dir) orelse return;
    const base = std.fs.path.dirname(app_root) orelse return;
    const legacy = std.fs.path.join(arena, &.{ base, "ghostpen", "tts" }) catch return;
    if (std.mem.eql(u8, legacy, dir)) return;
    const cwd = std.Io.Dir.cwd();
    var made = false;
    inline for (.{ tts.models, tts.voices }) |list| for (list) |item| {
        const from = std.fs.path.join(arena, &.{ legacy, item.file }) catch return;
        const to = std.fs.path.join(arena, &.{ dir, item.file }) catch return;
        const old = cwd.statFile(io, from, .{}) catch continue;
        if (old.size != item.size) continue;
        if (cwd.statFile(io, to, .{})) |_| continue else |_| {}
        if (!made) {
            cwd.createDirPath(io, dir) catch return;
            made = true;
        }
        if (cwd.rename(from, cwd, to, io)) {
            log.info("moved {s} from {s}", .{ item.file, legacy });
        } else |err| log.warn("cannot move {s} from {s}: {s}", .{ item.file, legacy, @errorName(err) });
    };
}

/// Point `oriel.tts` at GhostPen's models dir (once, at startup; `arena`
/// outlives the app). False when there is no data dir.
pub fn setUp(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map) bool {
    const dir = modelsDir(arena, env) orelse return false;
    adoptLegacy(arena, dir, io);
    tts.init(io, gpa, dir);
    shared_io = io;
    shared_gpa = gpa;
    ready = true;
    return true;
}

var shared_io: std.Io = undefined;
var shared_gpa: std.mem.Allocator = undefined;
var ready = false;

// ---- state: what the UI shows --------------------------------------------------------------

/// GhostPen's own "tts:state" emissions (the phases before `oriel.tts.speak`
/// takes over: "downloading", and errors in words); main.zig broadcasts it,
/// the CLI leaves it null.
pub var emit: ?*const fn (State) void = null;

var state_mutex: std.Io.Mutex = .init;
/// What GhostPen said last, while a reading is before `oriel.tts.speak`.
var own_state: State = .{ .phase = "idle", .message = "", .voice = "" };
var own_message: [256]u8 = undefined;
var own_voice: [32]u8 = undefined;
/// A worker is downloading for a reading (`own_state` is the truth then).
var preparing = false;
/// Bumped by every `speak` and `stop`: a stale worker says nothing more.
var generation: u64 = 0;

fn current(gen: u64) bool {
    state_mutex.lockUncancelable(shared_io);
    defer state_mutex.unlock(shared_io);
    return generation == gen;
}

/// Store and broadcast `s`, unless `gen` (a reading's) is no longer current.
fn setState(gen: ?u64, s: State) void {
    state_mutex.lockUncancelable(shared_io);
    defer state_mutex.unlock(shared_io);
    if (gen) |g| if (generation != g) return;
    const m = @min(s.message.len, own_message.len);
    const v = @min(s.voice.len, own_voice.len);
    @memcpy(own_message[0..m], s.message[0..m]);
    @memcpy(own_voice[0..v], s.voice[0..v]);
    own_state = .{ .phase = s.phase, .message = own_message[0..m], .voice = own_voice[0..v] };
    if (emit) |f| f(own_state);
}

/// The reading's state now (a window asks on load; updates come by event).
/// Valid until the next state change.
pub fn status() State {
    state_mutex.lockUncancelable(shared_io);
    const own = own_state;
    const prep = preparing;
    state_mutex.unlock(shared_io);
    if (prep or !ready) return own;
    // Not before the first reading: `oriel.tts.status` loads the GPU backends.
    if (std.mem.eql(u8, own.phase, "idle") or std.mem.eql(u8, own.phase, "error")) return own;
    const st = tts.status();
    if (!st.speaking) return .{ .phase = "idle", .message = "", .voice = "" };
    return .{ .phase = st.phase, .message = "", .voice = "" };
}

// ---- downloads -----------------------------------------------------------------------------

fn label(id: []const u8) []const u8 {
    if (tts.findModel(id)) |m| return m.label;
    if (tts.findVoice(id)) |v| return v.label;
    return id;
}

fn present(id: []const u8) bool {
    if (tts.findModel(id)) |m| return tts.modelPresent(m);
    if (tts.findVoice(id)) |v| return tts.voicePresent(v);
    return false;
}

/// `oriel.tts.download`, waiting out another download in progress (one at a
/// time; Settings may be fetching something else). Gives up once `gen`
/// (when given) is stale.
fn fetch(id: []const u8, gen: ?u64) !void {
    while (true) {
        tts.download(id) catch |err| {
            if (err != error.AlreadyDownloading) return err;
            if (gen) |g| if (!current(g)) return error.Cancelled;
            try shared_io.sleep(.fromMilliseconds(250), .awake);
            continue;
        };
        return;
    }
}

/// What a download error means to the user.
pub fn downloadMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ChecksumMismatch => "The download was damaged (checksum mismatch) and was deleted: try again.",
        error.Truncated => "The download stopped early: try again.",
        error.BadHttpStatus => "The server refused the download: try again later.",
        error.UnknownModel => "Unknown model or voice.",
        else => "The download failed: check the connection and try again.",
    };
}

/// What a speaking error means to the user.
pub fn speakMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoModel => "The voice model is not downloaded yet (Settings → Voices).",
        error.NoVoice, error.UnknownVoice => "The voice is not downloaded yet (Settings → Voices).",
        error.EspeakDataMissing => "No phoneme data (espeak-ng-data) was found next to GhostPen or on the system.",
        error.ModelLoadFailed => "Could not load the voice model: delete it in Settings → Voices and download it again.",
        error.VoiceFailed => "Could not load the voice: delete it in Settings → Voices and download it again.",
        error.LanguageFailed => "The voice can't read this language.",
        else => "Could not generate or play the voice. Try reading again.",
    };
}

// ---- reading -------------------------------------------------------------------------------

pub const Request = struct {
    text: []const u8,
    /// An espeak language, a translate target ("French"), or "" to guess.
    lang: []const u8 = "",
    /// A voice id, or "" for the language's.
    voice: []const u8 = "",
    /// A model id, or "" for the default (any on the device).
    model: []const u8 = "",
};

const Plan = struct {
    lang: []const u8,
    voice: []const u8,
    /// What must be downloaded first ("" when nothing).
    model_id: []const u8,
    voice_id: []const u8,
    options: tts.Options,
};

fn plan(req: Request) Plan {
    const lang = languageFor(req.text, req.lang);
    const voice = if (req.voice.len > 0) req.voice else voiceFor(lang);
    var model_id: []const u8 = "";
    if (req.model.len > 0) {
        if (!present(req.model)) model_id = req.model;
    } else {
        for (&tts.models) |*m| {
            if (tts.modelPresent(m)) break;
        } else model_id = tts.models[0].id;
    }
    return .{
        .lang = lang,
        .voice = voice,
        .model_id = model_id,
        .voice_id = if (present(voice)) "" else voice,
        .options = .{ .model = if (req.model.len > 0) req.model else "auto", .voice = voice, .lang = lang },
    };
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    req: Request,
    gen: u64,
};

/// Read `req` aloud on a worker (downloading what it needs first); returns
/// at once. A running reading stops.
pub fn speak(req: Request) void {
    if (!ready) return;
    const gen = blk: {
        state_mutex.lockUncancelable(shared_io);
        defer state_mutex.unlock(shared_io);
        generation += 1;
        break :blk generation;
    };
    tts.stop();
    const job = shared_gpa.create(Job) catch return;
    job.* = .{ .arena = .init(shared_gpa), .req = undefined, .gen = gen };
    const a = job.arena.allocator();
    job.req = .{
        .text = a.dupe(u8, req.text) catch return dropJob(job),
        .lang = a.dupe(u8, req.lang) catch return dropJob(job),
        .voice = a.dupe(u8, req.voice) catch return dropJob(job),
        .model = a.dupe(u8, req.model) catch return dropJob(job),
    };
    const t = std.Thread.spawn(.{}, runJob, .{job}) catch |err| {
        log.err("cannot start the reading: {s}", .{@errorName(err)});
        setState(gen, .{ .phase = "error", .message = "Could not start the voice", .voice = "" });
        return dropJob(job);
    };
    t.detach();
}

fn dropJob(job: *Job) void {
    job.arena.deinit();
    shared_gpa.destroy(job);
}

fn setPreparing(on: bool) void {
    state_mutex.lockUncancelable(shared_io);
    defer state_mutex.unlock(shared_io);
    preparing = on;
}

fn runJob(job: *Job) void {
    defer dropJob(job);
    const gen = job.gen;
    const p = plan(job.req);
    // 1. The model and the voice, the first time (verified downloads).
    setPreparing(true);
    for ([_][]const u8{ p.model_id, p.voice_id }) |id| {
        if (id.len == 0) continue;
        if (!current(gen)) return setPreparing(false);
        setState(gen, .{ .phase = "downloading", .message = label(id), .voice = p.voice });
        fetch(id, gen) catch |err| {
            setPreparing(false);
            if (err == error.Cancelled) return;
            log.err("download {s}: {s}", .{ id, @errorName(err) });
            setState(gen, .{ .phase = "error", .message = downloadMessage(err), .voice = "" });
            return;
        };
    }
    setPreparing(false);
    if (!current(gen)) return;
    // 2. oriel.tts reads it ("tts:state" follows it from here).
    setState(gen, .{ .phase = "loading", .message = "", .voice = p.voice });
    const r = tts.speak(job.arena.allocator(), job.req.text, p.options) catch |err| {
        log.err("reading failed: {s}", .{@errorName(err)});
        setState(gen, .{ .phase = "error", .message = speakMessage(err), .voice = "" });
        return;
    };
    logResult(r);
    // Mirror the end for `status` (the event already went out).
    state_mutex.lockUncancelable(shared_io);
    defer state_mutex.unlock(shared_io);
    if (generation == gen) own_state = .{ .phase = "idle", .message = if (r.stopped) "Stopped" else "Finished", .voice = "" };
}

fn logResult(r: tts.Result) void {
    log.info("read {s} ({s}) on {s}: first audio {d} ms (load {d} ms), {d} chunks, {d:.1} s of audio in {d} ms{s}", .{
        r.voice,  r.lang,  r.backend,  r.first_audio_ms, r.load_ms,
        r.chunks, r.audio_s, r.synth_ms, if (r.stopped) ", stopped" else "",
    });
}

/// Stop the current reading (or the download it waits for).
pub fn stop() void {
    if (!ready) return;
    {
        state_mutex.lockUncancelable(shared_io);
        defer state_mutex.unlock(shared_io);
        generation += 1;
    }
    tts.stop();
    setState(null, .{ .phase = "idle", .message = "Stopped", .voice = "" });
}

/// Load the model and voice a reading in `lang` ("" for English) would use,
/// so it starts sooner; nothing when they aren't downloaded. Blocks.
pub fn warmUp(lang: []const u8) void {
    if (!ready) return;
    const l = if (lang.len == 0) "en-us" else espeakLanguageFor(lang) orelse lang;
    const v = voiceFor(l);
    if (!present(v)) return;
    tts.warmUp(.{ .voice = v, .lang = l }) catch |err| switch (err) {
        error.NoModel, error.NoVoice => {},
        else => log.warn("warm-up: {s}", .{@errorName(err)}),
    };
}

/// `ghostpen --say`: read `req` aloud in the foreground, downloading what
/// it needs first (progress on stderr).
pub fn say(gpa: std.mem.Allocator, req: Request) !tts.Result {
    const p = plan(req);
    for ([_][]const u8{ p.model_id, p.voice_id }) |id| {
        if (id.len == 0) continue;
        std.debug.print("Downloading {s}…\n", .{label(id)});
        fetch(id, null) catch |err| {
            std.debug.print("{s}\n", .{downloadMessage(err)});
            return err;
        };
    }
    std.debug.print("GhostPen's voice: {s} ({s})…\n", .{ p.voice, p.lang });
    const r = tts.speak(gpa, req.text, p.options) catch |err| {
        std.debug.print("The voice failed: {s}\n", .{speakMessage(err)});
        return err;
    };
    logResult(r);
    return r;
}

// ---- the catalog for Settings → Voices -----------------------------------------------------

pub const Entry = struct {
    /// "kokoro-82m-q8_0" (models) or "ef_dora" (voices).
    id: []const u8,
    label: []const u8,
    /// Voices: the espeak language they read ("" for models).
    lang: []const u8 = "",
    note: []const u8 = "",
    size: u64 = 0,
    downloaded: bool = false,
};

pub const CatalogInfo = struct {
    models: []Entry,
    voices: []Entry,
    /// The phoneme data the engine reads (bundled with GhostPen, or the system's).
    espeak_ready: bool,
    /// Where it was found ("" when not).
    espeak_source: []const u8,
    /// Where the voice runs: the loaded model's backend ("CPU", "Vulkan0"),
    /// else the GPU backend ggml found, else "CPU".
    backend: []const u8,
    gpu: ?[]const u8,
    /// The model or voice being downloaded, "" when none.
    downloading: []const u8,
    /// The reading's phase.
    phase: []const u8,
};

fn modelNote(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "kokoro-82m-q8_0")) return "every voice reads it · this is the default";
    if (std.mem.eql(u8, id, "kokoro-82m-f16")) return "slightly fuller sound";
    return "";
}

/// What Settings → Voices lists: the models, the curated voices, whether
/// the phoneme data is there and where the voice runs.
pub fn catalog(arena: std.mem.Allocator) !CatalogInfo {
    if (!ready) return error.NoDataDir;
    const st = tts.status();
    const models = try arena.alloc(Entry, st.models.len);
    for (st.models, models) |m, *e| {
        const size = tts.findModel(m.id).?.size;
        e.* = .{ .id = m.id, .label = m.label, .note = modelNote(m.id), .size = size, .downloaded = m.present };
    }
    const voices = try arena.alloc(Entry, st.voices.len);
    for (st.voices, voices) |v, *e| {
        const size = tts.findVoice(v.id).?.size;
        e.* = .{ .id = v.id, .label = v.label, .lang = v.lang, .size = size, .downloaded = v.present };
    }
    return .{
        .models = models,
        .voices = voices,
        .espeak_ready = st.espeak_data != null,
        .espeak_source = if (st.espeak_data) |d| try arena.dupe(u8, d) else "",
        .backend = try arena.dupe(u8, st.backend),
        .gpu = if (st.gpu) |g| try arena.dupe(u8, g) else null,
        .downloading = if (st.downloading) |d| try arena.dupe(u8, d) else "",
        .phase = status().phase,
    };
}

/// Settings → Voices: download a model or voice ("tts:download" reports it).
pub fn download(id: []const u8) !void {
    if (!ready) return error.NoDataDir;
    try tts.download(id);
}

/// Settings → Voices: remove a model or voice (a reading using it stops).
pub fn delete(id: []const u8) !void {
    if (!ready) return error.NoDataDir;
    tts.delete(id) catch |err| {
        if (err != error.Speaking) return err;
        stop();
        // The reading returns at its next chunk.
        var tries: u32 = 0;
        while (tries < 50) : (tries += 1) {
            shared_io.sleep(.fromMilliseconds(100), .awake) catch {};
            tts.delete(id) catch |again| {
                if (again == error.Speaking) continue;
                return again;
            };
            return;
        }
        return err;
    };
}

// ---- tests ---------------------------------------------------------------------------------

test "translate targets map to espeak languages" {
    try std.testing.expectEqualStrings("fr", espeakLanguageFor("French").?);
    try std.testing.expectEqualStrings("pt-br", espeakLanguageFor("portuguese").?);
    try std.testing.expect(espeakLanguageFor("Klingon") == null);
    try std.testing.expectEqualStrings("it", languageFor("anything", "Italian"));
    try std.testing.expectEqualStrings("en-gb", languageFor("anything", "en-gb"));
}

test "the language guesser keeps GhostPen's cases (oriel.tts.guessLanguage)" {
    try std.testing.expectEqualStrings("es", languageFor("El coche rojo avanza por la ciudad, y las campanas suenan a lejos.", ""));
    try std.testing.expectEqualStrings("en-us", languageFor("The committee reviews the design every quarter.", ""));
    try std.testing.expectEqualStrings("es", languageFor("¿Cómo está la señal?", "auto"));
    try std.testing.expectEqualStrings("zh", languageFor("今天天气很好。", ""));
    try std.testing.expectEqualStrings("ja", languageFor("今日はとても良い天気です", ""));
}

test "the catalog keeps GhostPen's file names (downloads from earlier builds stay usable)" {
    try std.testing.expectEqualStrings("kokoro-82m-q8_0.gguf", tts.findModel("kokoro-82m-q8_0").?.file);
    try std.testing.expectEqualStrings("kokoro-voice-af_heart.gguf", tts.findVoice("af_heart").?.file);
    try std.testing.expectEqualStrings("kokoro-voice-ef_dora.gguf", tts.findVoice("ef_dora").?.file);
}

test "earlier builds' voice files move in and the catalog lists them as downloaded" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const blank = try t.allocator.alloc(u8, tts.findVoice("ef_dora").?.size);
    defer t.allocator.free(blank);
    @memset(blank, 0);
    try tmp.dir.createDirPath(t.io, "ghostpen/tts");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ghostpen/tts/kokoro-voice-ef_dora.gguf", .data = blank });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ghostpen/tts/kokoro-voice-af_heart.gguf", .data = "truncated" });

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator());
    const dir = try std.fs.path.join(arena.allocator(), &.{ base, "GhostPen", "tts" });
    adoptLegacy(arena.allocator(), dir, t.io);
    tts.init(t.io, t.allocator, dir);
    shared_io = t.io;
    ready = true;
    defer {
        ready = false;
        tts.deinit();
    }
    const info = try catalog(arena.allocator());
    for (info.voices) |v| try t.expectEqual(std.mem.eql(u8, v.id, "ef_dora"), v.downloaded);
    for (info.models) |m| try t.expect(!m.downloaded);
    try t.expectEqualStrings("ef_dora", voiceFor("es"));
    try t.expectEqualStrings("ff_siwis", voiceFor("fr")); // to download
    try t.expectEqualStrings("idle", info.phase);
}
