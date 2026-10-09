//! The built-in voice: Kokoro-82M offline text-to-speech, synthesized and
//! played inside the app (kokoro.cpp + espeak-ng compiled in through Oriel's
//! `-Dkokoro`; playback through the vendored miniaudio).
//!
//! First use downloads the voice model (~135 MB) and a voice pack (0.5 MB)
//! into `<data dir>/GhostPen/tts` — the same verified-resume downloads the
//! model list uses (llm_models.zig does the fetching). The espeak-ng phoneme
//! data comes from the system package (Linux), Homebrew (macOS) or
//! GhostPen's own tts dir once present. One request at a time: a newer
//! `speak` or `stop` cancels the running one. Plain std: the CLI (`--say`)
//! uses it directly.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const llm_models = @import("llm_models.zig");

const log = std.log.scoped(.tts);

const Arena = std.heap.ArenaAllocator;

// ---- the model and voice catalog ---------------------------------------------------------

/// Model catalog entries (simonfxr/kokoro.cpp-GGUF; the SHA-256s are the
/// repo's manifest.json, verified on download like every other model).
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    note: []const u8 = "",
};

pub const Voice = struct {
    /// The Kokoro voice id, also the file's stem (`af_heart` → `kokoro-voice-af_heart.gguf`).
    id: []const u8,
    /// The espeak-ng language this voice reads ("en-us", "es", "fr", ...).
    lang: []const u8,
    label: []const u8,
    size: u64 = 522560,
    sha256: []const u8,
};

pub const models = [_]Model{
    .{ .id = "kokoro-82m-q8_0", .name = "Kokoro 82M (Q8_0)", .file = "kokoro-82m-q8_0.gguf", .size = 141322752, .sha256 = "61cc0186b3a761bdc31ba5d83b9228e4a72bf974cc5b94c281a5f450e683d2cc", .note = "135 MB · every voice reads it · this is the default" },
    .{ .id = "kokoro-82m-f16", .name = "Kokoro 82M (F16)", .file = "kokoro-82m-f16.gguf", .size = 163728096, .sha256 = "597926de84f5550e1526ce0abde4e496209d464afc9274d8603d14f3c04d1f67", .note = "156 MB · slightly fuller sound" },
};

/// The curated voice list (the GGUF repo carries all 54 official voice
/// packs; these cover the languages the translate menu offers).
pub const voices = [_]Voice{
    .{ .id = "af_heart", .lang = "en-us", .label = "English (US) · Heart", .sha256 = "c2f44076dfb8f9c098a85d634f6d6b46b038f80e3afdf695ff3b90f6d9ef473f" },
    .{ .id = "af_bella", .lang = "en-us", .label = "English (US) · Bella", .sha256 = "63d24d0e5d91cb6cf3bca294a3b8c0b4428aa54ac9b5de42e5ba07f6bd110ea8" },
    .{ .id = "af_nicole", .lang = "en-us", .label = "English (US) · Nicole", .sha256 = "04bee67dd22b1eb687e50187c6851db96b6a1ebeee96daf5ec9448427a1bce42" },
    .{ .id = "am_michael", .lang = "en-us", .label = "English (US) · Michael", .sha256 = "a2b71b49dd6320a2e235f8dfd176b197a2f76d5b32c1e3222efb08f117e78335" },
    .{ .id = "am_fenrir", .lang = "en-us", .label = "English (US) · Fenrir", .sha256 = "3983d48599b5e219f581ea4fbc186d9181101d282cd2715d521775ba8a6ba882" },
    .{ .id = "bf_emma", .lang = "en-gb", .label = "English (UK) · Emma", .sha256 = "78d519c9bfd34b5e15475169d0757cc77a8a3053d05dce65d3fcb77bf6743448" },
    .{ .id = "ef_dora", .lang = "es", .label = "Español · Dora", .sha256 = "7fa2a87038c41301363e8e7d97bad2260c20da1a786ec22e0ea954d67dc4c412" },
    .{ .id = "em_alex", .lang = "es", .label = "Español · Alex", .sha256 = "bf44594da819e77b4575d9912b8d4b2ab73d67a6a2b17031412a826b98db2b6f" },
    .{ .id = "ff_siwis", .lang = "fr", .label = "Français · Siwis", .sha256 = "ebeb2847f5a56301af4d61fd31e5c568dfc05b4017694784e86eff9b17d08296" },
    .{ .id = "pf_dora", .lang = "pt-br", .label = "Português · Dora", .sha256 = "a08314e467100dcb995d520ac0ccc52860d3b0484df7be1a51308a26127e72bd" },
    .{ .id = "if_sara", .lang = "it", .label = "Italiano · Sara", .sha256 = "cfc7d3a2ab08df1791ea0e4518c66d0191e91376b1ae437adea826d9556b7b70" },
    .{ .id = "jf_alpha", .lang = "ja", .label = "日本語 · Alpha", .sha256 = "482bf66e90ff6f42c0edf30ec4fb7f7d840347d4b76e8c3ea2bb59932c29f441" },
    .{ .id = "zf_xiaobei", .lang = "zh", .label = "中文 · Xiaobei", .sha256 = "9d6ab39cba27274ace22170c47e1c4bafe556d95413fd2fe3b8d5be1f37c2fbb" },
    .{ .id = "hf_alpha", .lang = "hi", .label = "हिन्दी · Alpha", .sha256 = "e1948214324b9af419ab10053caeb303752f4feee6e641d1dae9a04cdcd57036" },
};

pub fn findVoice(id: []const u8) ?Voice {
    for (voices) |v| if (std.mem.eql(u8, v.id, id)) return v;
    return null;
}

pub fn findModel(id: []const u8) ?Model {
    for (models) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

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

/// The voice whose language matches, else the default US English one.
pub fn voiceForLanguage(lang: []const u8) []const u8 {
    for (voices) |v| if (std.mem.eql(u8, v.lang, lang)) return v.id;
    return "af_heart";
}

/// A cheap guess over the text the user selected: unicode ranges for CJK and
/// kana, then function-word matching for Spanish vs English (the two languages
/// one is most likely to confuse on a Latin-Alphabet desktop), accent density
/// as the last Spanish hint. Nothing clever: covers the catalog's languages.
pub fn guessLanguage(text: []const u8) []const u8 {
    var cjk: usize = 0;
    var kana: usize = 0;
    var latin: usize = 0;
    var accented: usize = 0;
    var i: usize = 0;
    var strong_es: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            continue;
        };
        switch (cp) {
            0x0400...0x04FF => return "ru", // cyrillic (espeak): say nothing and leave
            0x4E00...0x9FFF, 0x3400...0x4DBF => cjk += 1,
            0x3040...0x30FF => kana += 1,
            // Spanish tell-tales: ñ, ¿ and ¡ (English text never carries them).
            0x00F1, 0x00BF, 0x00A1 => {
                latin += 1;
                accented += 1;
                strong_es += 1;
            },
            0x00C0...0x00F0, 0x00F2...0x00FF, // latin-1 supplement (á, é, í, ó, ú, ü; ñ/¿/¡ above)
            0x0100...0x024F => {
                latin += 1;
                accented += 1;
            },
            0x0041...0x007A => latin += 1,
            else => {},
        }
        i += len;
    }
    if (strong_es > 0) return "es";
    if (kana > cjk / 4) return "ja";
    if (cjk > 0 and kana == 0) return "zh";
    if (latin == 0) return "en-us";
    // Spanish markers as English-reserving word markers.
    const es_words = [_][]const u8{ "el", "la", "los", "las", "un", "una", "de", "del", "que", "con", "para", "por", "es", "son", "esta", "están", "más", "sí", "en", "su", "su", "año", "sobre" };
    const en_words = [_][]const u8{ "the", "a", "an", "of", "and", "or", "to", "in", "is", "are", "it", "that", "with", "for", "on", "as", "this", "be", "was" };
    var es_hits: usize = 0;
    var en_hits: usize = 0;
    var word_it = std.mem.tokenizeAny(u8, text, " ,;:.!?()[]{}\"/\t\r\n");
    while (word_it.next()) |w| {
        for (es_words) |ew| {
            if (std.ascii.eqlIgnoreCase(w, ew)) {
                es_hits += 1;
                break;
            }
        }
        for (en_words) |ew| {
            if (std.ascii.eqlIgnoreCase(w, ew)) {
                en_hits += 1;
                break;
            }
        }
    }
    if (es_hits >= en_hits * 2 and es_hits > 1) return "es";
    if (en_hits > es_hits * 2 and en_hits > 1) return "en-us";
    // Accent density above 12% says Spanish over plain English; otherwise the
    // default voice stays (the UK/US voices read most Latin text passably).
    if (accented * 100 / (1 + latin) > 12) return "es";
    return "en-us";
}

// ---- state: what the UI shows and which request is current -------------------------------

pub const Phase = enum { idle, downloading, generating, playing, error_state };

pub const State = struct {
    phase: Phase = .idle,
    /// What the user sees, empty when idle.
    message: []const u8 = "",
    /// 0–1 while downloading and while playing.
    progress: f64 = 0,
    /// The voice sounding now ("" while generating).
    voice: []const u8 = "",
};

var state_mutex: std.Io.Mutex = .init;
var app_state: State = .{};

/// Event into the UI: main.zig sets this to broadcast `ghostpen://tts-state`;
/// the CLI path leaves it null.
pub var emit: ?*const fn (State) void = null;

fn setState(s: State) void {
    state_mutex.lockUncancelable(io);
    app_state = s;
    state_mutex.unlock(io);
    if (emit) |f| f(s);
}

pub fn status() State {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    return app_state;
}

/// Bumped to invalidate the request a busy worker holds: a new speak or a
/// stop while generating makes the running one drop its output.
var generation: u64 = 0;

fn currentGeneration() u64 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    return generation;
}

fn bumpGeneration() u64 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    generation += 1;
    return generation;
}

// ---- files and dirs ------------------------------------------------------------------------

pub const Dirs = struct {
    /// `<data dir>/GhostPen/tts`.
    root: []const u8,
};

/// The model URL scheme on Hugging Face (the download machinery takes plain URLs).
pub const repoUrl = "https://huggingface.co/simonfxr/kokoro.cpp-GGUF/resolve/main/";

/// The tts dir; null when the app has no data dir at all (the helper class
/// contains the models dir we sit next to).
pub fn dirs(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?Dirs {
    const own = llm_models.ownDir(arena, env) orelse return null;
    const app_root = std.fs.path.dirname(own) orelse return null;
    return Dirs{
        .root = std.fs.path.join(arena, &.{ app_root, "tts" }) catch return null,
    };
}

fn modelFile(arena: std.mem.Allocator, d: Dirs, file: []const u8) ?[]const u8 {
    const path = std.fs.path.join(arena, &.{ d.root, file }) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    _ = st.size;
    return path;
}

fn voiceFile(arena: std.mem.Allocator, d: Dirs, id: []const u8) ?[]const u8 {
    const name = std.fmt.allocPrint(arena, "kokoro-voice-{s}.gguf", .{id}) catch return null;
    const path = std.fs.path.join(arena, &.{ d.root, name }) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    _ = st.size;
    return path;
}

/// The espeak-ng phoneme data the engine reads IPA phonemes from: the
/// GHOSTPEN_ESPEAK_DATA env var, GhostPen's own `<tts>/espeak-ng-data`, then
/// the system package (Linux) or Homebrew (macOS). Duplicated into `arena`.
pub fn espeakDataDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map, d: ?Dirs) ?[]const u8 {
    if (env.get("GHOSTPEN_ESPEAK_DATA")) |p| if (p.len > 0) {
        if (hasPhondata(arena, p)) return arena.dupe(u8, p) catch null;
    };
    if (d) |dirs_| {
        const own = std.fmt.allocPrint(arena, "{s}/espeak-ng-data", .{dirs_.root}) catch null;
        if (own) |o| if (hasPhondata(arena, o)) return o;
    }
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/opt/homebrew/share/espeak-ng-data", "/usr/local/share/espeak-ng-data" },
        else => &.{ "/usr/share/espeak-ng-data", "/usr/local/share/espeak-ng-data" },
    };
    for (candidates) |c| {
        if (hasPhondata(arena, c)) return arena.dupe(u8, c) catch null;
    }
    return null;
}

fn hasPhondata(arena: std.mem.Allocator, dir: []const u8) bool {
    const probe = std.fmt.allocPrint(arena, "{s}/phondata", .{dir}) catch return false;
    const st = std.Io.Dir.cwd().statFile(io, probe, .{}) catch return false;
    _ = st.size;
    return true;
}

// ---- the engine -----------------------------------------------------------------------------

const Context = oriel.kokoro.Context;

var engine: ?*Context = null;
var engine_model_file: []const u8 = "";
var engine_voice: []const u8 = "";
var engine_lang: []const u8 = "";
var engine_lock: std.Io.Mutex = .init;
var espeak_env_ready: bool = false;

/// `KOKORO_ESPEAK_DATA_PATH` must be in the environment before espeak's
/// first init — kokoro.cpp reads it lazily once per process.
fn ensureEspeakEnv(data_dir: []const u8) void {
    if (espeak_env_ready) return;
    switch (builtin.os.tag) {
        .windows => {
            // Windows keeps CRT's env for _putenv; the data next to the exe
            // is espeak's own fallback. TODO: _putenv for GhostPen's dir.
            log.info("tts: Windows reads espeak data next to the exe", .{});
        },
        else => {
            const zdir = std.heap.page_allocator.dupeZ(u8, data_dir) catch return;
            defer std.heap.page_allocator.free(zdir);
            if (setenv("KOKORO_ESPEAK_DATA_PATH", zdir, 1) == 0) {
                espeak_env_ready = true;
                log.info("tts: espeak data at {s}", .{data_dir});
            }
        },
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const LoadResult = union(enum) {
    ok,
    /// A message for the user (missing model/voice download case).
    missing: []const u8,
    /// An engine failure, message as-is.
    failed: []const u8,
};

/// Load (and keep) the engine in `model_id`/`voice`/`lang`. A voice or
/// language change re-voices the running context cheaply; a model change
/// reloads it. Caller holds `engine_lock`.
fn ensureEngine(arena: std.mem.Allocator, d: Dirs, model_id: []const u8, voice: []const u8, lang: []const u8, espeak_dir: []const u8) LoadResult {
    ensureEspeakEnv(espeak_dir);
    const model = findModel(model_id) orelse models[0];
    const model_path = modelFile(arena, d, model.file) orelse return .{ .missing = "The voice model is not downloaded yet" };
    if (engine) |ctx| {
        if (!std.mem.eql(u8, engine_model_file, model_path)) {
            oriel.kokoro.free(ctx);
            engine = null;
        }
    }
    if (engine == null) {
        const mp = arena.dupeZ(u8, model_path) catch return .{ .failed = "out of memory" };
        var params = oriel.kokoro.defaultParams();
        params.n_threads = 4;
        params.length_scale = 1.0;
        params.backend = oriel.kokoro.c.KOKORO_BACKEND_AUTO;
        engine = oriel.kokoro.init(mp, params) orelse {
            return .{ .failed = std.fmt.allocPrint(arena, "Could not load the voice model ({s})", .{oriel.kokoro.lastError()}) catch "Could not load the voice model" };
        };
        engine_model_file = mp;
        engine_voice = "";
        engine_lang = "";
    }
    const ctx = engine.?;
    if (std.mem.eql(u8, engine_voice, voice) and std.mem.eql(u8, engine_lang, lang)) return .ok;

    const vp = voiceFile(arena, d, voice) orelse return .{ .missing = "The voice is not downloaded yet" };
    const vpz = arena.dupeZ(u8, vp) catch return .{ .failed = "out of memory" };
    const langz = arena.dupeZ(u8, lang) catch return .{ .failed = "out of memory" };
    oriel.kokoro.loadVoice(ctx, vpz) catch {
        return .{ .failed = std.fmt.allocPrint(arena, "Could not load the voice ({s})", .{oriel.kokoro.lastError()}) catch "Could not load the voice" };
    };
    oriel.kokoro.setLanguage(ctx, langz) catch {
        return .{ .failed = std.fmt.allocPrint(arena, "The language is not available ({s})", .{oriel.kokoro.lastError()}) catch "The language is not available" };
    };
    engine_voice = voice;
    engine_lang = langz;
    return .ok;
}

// ---- playback: the vendored miniaudio through oriel.audio_play ------------------------------
var holding_samples: ?[]f32 = null;


fn playProgress(fraction: f64) void {
    setState(.{ .phase = .playing, .progress = fraction, .message = "", .voice = engine_voice });
}

fn playDone() void {
    // Called on the device thread when the utterance ended (the chained
    // request loop spun on `finished()` before this for the last chunk).
    if (holding_samples) |s| {
        gpa.free(s);
        holding_samples = null;
    }
    setState(.{ .phase = .idle, .message = "", .progress = 0, .voice = "" });
}

fn stopPlayback() void {
    oriel.audio_play.stop();
    if (holding_samples) |s| {
        gpa.free(s);
        holding_samples = null;
    }
    setState(.{ .phase = .idle, .message = "", .progress = 0, .voice = "" });
}

fn playSamples(proc_io: std.Io, samples: []const f32, rate: u32) !void {
    oriel.audio_play.start(proc_io, gpa, samples, rate) catch |err| {
        return err;
    };
}

// ---- the worker -----------------------------------------------------------------------------

pub var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;
var shared_env: *const std.process.Environ.Map = undefined;
var shared_dirs: ?Dirs = null;
var globals_ready = false;

/// Called once from main before any use, with the process environment and
/// the app's data dir; the app wires `emit` here.
pub fn init(emit_fn: ?*const fn (State) void, proc_io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, d: ?Dirs) void {
    emit = emit_fn;
    io = proc_io;
    gpa = allocator;
    shared_env = env;
    shared_dirs = d;
    oriel.audio_play.on_progress = playProgress;
    oriel.audio_play.on_done = playDone;
    globals_ready = true;
    setState(.{ .phase = .idle });
}

const Request = struct {
    arena: Arena,
    text: []const u8,
    lang: []const u8,
    voice: []const u8,
    model_id: []const u8,
    gen: u64,
};

fn runRequest(req: *Request) void {
    defer {
        req.arena.deinit();
        gpa.destroy(req);
    }
    const arena = req.arena.allocator();
    const d = shared_dirs orelse {
        setState(.{ .phase = .error_state, .message = "The app has no data dir", .progress = 0 });
        return;
    };
    const is_cancelled = struct {
        fn f(r: *const Request) bool {
            return currentGeneration() != r.gen;
        }
    }.f;

    // 1. The model (a one-time ~135 MB download; resumable and verified).
    const model = findModel(req.model_id) orelse models[0];
    if (modelFile(arena, d, model.file) == null) {
        setState(.{ .phase = .downloading, .message = model.name, .progress = 0 });
        var http_status: std.http.Status = undefined;
        const url = std.fmt.allocPrint(arena, "{s}{s}", .{ repoUrl, model.file }) catch {
            setState(.{ .phase = .error_state, .message = "out of memory" });
            return;
        };
        _ = llm_models.downloadFile(io, gpa, arena, d.root, model.id, model.file, url, model.size, model.sha256, {}, onDownloadProgress, &http_status) catch |err| {
            if (is_cancelled(req) or err == error.Cancelled) {
                setState(.{ .phase = .idle, .message = "" });
            } else {
                setState(.{ .phase = .error_state, .message = "Could not download the voice model", .progress = 0 });
            }
            return;
        };
    }

    // 2. The voice pack.
    if (voiceFile(arena, d, req.voice) == null) {
        const v = findVoice(req.voice) orelse {
            setState(.{ .phase = .error_state, .message = "Unknown voice", .progress = 0 });
            return;
        };
        setState(.{ .phase = .downloading, .message = v.label, .progress = 0 });
        var http_status: std.http.Status = undefined;
        const name = std.fmt.allocPrint(arena, "kokoro-voice-{s}.gguf", .{req.voice}) catch return;
        const url = std.fmt.allocPrint(arena, "{s}voices/{s}", .{ repoUrl, name }) catch return;
        _ = llm_models.downloadFile(io, gpa, arena, d.root, req.voice, name, url, v.size, v.sha256, {}, onDownloadProgress, &http_status) catch |err| {
            if (is_cancelled(req) or err == error.Cancelled) {
                setState(.{ .phase = .idle, .message = "" });
            } else {
                setState(.{ .phase = .error_state, .message = "Could not download the voice", .progress = 0 });
            }
            return;
        };
    }

    // 3. The espeak-ng phoneme data.
    const espeak_dir = espeakDataDir(arena, shared_env, d) orelse {
        setState(.{ .phase = .error_state, .message = "No phoneme data (Settings → Speech)", .progress = 0 });
        return;
    };

    // 4. The engine.
    setState(.{ .phase = .generating, .message = "Loading the voice", .progress = 0, .voice = "" });
    engine_lock.lockUncancelable(io);
    switch (ensureEngine(arena, d, req.model_id, req.voice, req.lang, espeak_dir)) {
        .ok => {},
        .missing, .failed => |msg| {
            engine_lock.unlock(io);
            setState(.{ .phase = .error_state, .message = msg, .progress = 0 });
            return;
        },
    }
    if (is_cancelled(req)) {
        engine_lock.unlock(io);
        setState(.{ .phase = .idle });
        return;
    }
    // 5. The synthesis.
    const synth = oriel.kokoro.synthesize(engine.?, req.text) catch {
        engine_lock.unlock(io);
        setState(.{ .phase = .error_state, .message = "The synthesis failed", .progress = 0 });
        return;
    };
    engine_lock.unlock(io);
    log.info("tts synthesized {d} samples @ {d} Hz", .{ synth.samples.len, synth.rate });
    if (synth.samples.len == 0) {
        oriel.kokoro.freePcm(synth.samples);
        setState(.{ .phase = .idle, .message = "" });
        return;
    }
    if (is_cancelled(req)) {
        oriel.kokoro.freePcm(synth.samples);
        setState(.{ .phase = .idle });
        return;
    }

    // 6. Chunk into sentences (the engine synthesizes one utterance at a
    // time) and play them in sequence until cancel.
    const chunks = splitChunks(arena, req.text) catch return;
    oriel.kokoro.freePcm(synth.samples);
    if (synth.samples.len > 0) {
        // The engine's first chunk is already covering the head; the rest
        // are from here on (the splitChunks call above was pre-cache).
        for (chunks, 0..) |chunk_text, i| {
            if (is_cancelled(req)) break;
            const st_goal = std.fmt.allocPrint(arena, "Speaking {d}/{d}", .{ i + 1, chunks.len }) catch "";
            setState(.{ .phase = .generating, .message = st_goal, .progress = 0, .voice = "" });
            engine_lock.lockUncancelable(io);
            const once = oriel.kokoro.synthesize(engine.?, chunk_text) catch {
                engine_lock.unlock(io);
                setState(.{ .phase = .error_state, .message = "The synthesis failed", .progress = 0 });
                return;
            };
            engine_lock.unlock(io);
            if (is_cancelled(req)) {
                oriel.kokoro.freePcm(once.samples);
                break;
            }
            const play_samples = gpa.dupe(f32, once.samples) catch {
                oriel.kokoro.freePcm(once.samples);
                setState(.{ .phase = .idle });
                return;
            };
            oriel.kokoro.freePcm(once.samples);
            _ = once.rate;
            holding_samples = play_samples;
            // audio_play ends its device; when it finishes it frees the buffer.
            playSamples(io, play_samples, synth.rate) catch {
                gpa.free(play_samples);
                holding_samples = null;
                setState(.{ .phase = .error_state, .message = "The audio device failed", .progress = 0 });
                return;
            };
            // Wait until the device ran the buffer out (or a stop).
            while (true) {
                io.sleep(.fromMilliseconds(30), .awake) catch return;
                if (is_cancelled(req)) break;
                if (oriel.audio_play.finished()) break;
            }
        }
    }
    if (!is_cancelled(req)) setState(.{ .phase = .idle, .message = "" });
}

/// Split on sentence boundaries into ~250-char chunks (a Kokoro utterance
/// stays bounded); returns [] []const u8 owned by `arena`.
fn splitChunks(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const breakers = ".!?\n";
    var start: usize = 0;
    var last_break: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n' or std.mem.indexOfScalar(u8, breakers, ch) != null) {
            last_break = i + 1;
        }
        if (i - start >= 220 and last_break > start) {
            const end = trimEnd(text, start, last_break);
            if (end > start) try list.append(arena, text[start..end]);
            start = last_break;
        }
    }
    if (start < text.len) {
        const end = trimEnd(text, start, text.len);
        if (end > start) try list.append(arena, text[start..end]);
    }
    if (list.items.len == 0) {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) try list.append(arena, trimmed);
    }
    return list.items;
}

fn trimEnd(text: []const u8, a: usize, b: usize) usize {
    var end = b;
    while (end > a and containsOnlyWhitespace(text[end - 1])) end -= 1;
    return end;
}

fn containsOnlyWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn onDownloadProgress(_: void, progress: llm_models.Progress) void {
    const total: f64 = if (progress.total > 0) @floatFromInt(progress.total) else 0.0;
    const frac = if (total > 0) @as(f64, @floatFromInt(progress.done)) / total else 0.0;
    setState(.{ .phase = .downloading, .message = progress.message, .progress = frac });
    // The Settings window's detailed channel (ghostpen://tts-download).
    if (emitDownload) |f| f(progress);
}

/// Emissions for the download UI (Settings), set by main.zig.
pub var emitDownload: ?*const fn (llm_models.Progress) void = null;

pub fn speak(text: []const u8, lang: []const u8, voice: []const u8, model_id: []const u8) void {
    if (!globals_ready) return;
    // One at a time: a new request stops the current one and takes over.
    stopPlayback();
    _ = bumpGeneration();
    const gen = currentGeneration();

    const req = gpa.create(Request) catch return;
    var arena = Arena.init(gpa);
    const a = arena.allocator();
    req.* = .{
        .arena = arena,
        .text = a.dupe(u8, text) catch {
            arena.deinit();
            gpa.destroy(req);
            return;
        },
        .lang = a.dupe(u8, lang) catch {
            arena.deinit();
            gpa.destroy(req);
            return;
        },
        .voice = a.dupe(u8, voice) catch {
            arena.deinit();
            gpa.destroy(req);
            return;
        },
        .model_id = a.dupe(u8, model_id) catch {
            arena.deinit();
            gpa.destroy(req);
            return;
        },
        .gen = gen,
    };
    setState(.{ .phase = .generating, .message = "Starting…", .progress = 0, .voice = "" });
    const t = std.Thread.spawn(.{}, runRequest, .{req}) catch |err| {
        req.arena.deinit();
        gpa.destroy(req);
        setState(.{ .phase = .error_state, .message = "Could not start the voice", .progress = 0 });
        log.err("tts: thread spawn failed ({s})", .{@errorName(err)});
        return;
    };
    t.detach();
}

/// Stop the current play or cancel the current generation.
pub fn stop() void {
    _ = bumpGeneration();
    stopPlayback();
}

/// Free the engine on app exit (the audio device stops on its own).
pub fn shutdown() void {
    stop();
    engine_lock.lockUncancelable(io);
    defer engine_lock.unlock(io);
    if (engine) |ctx| {
        oriel.kokoro.free(ctx);
        engine = null;
    }
}

// ---- the catalog for the Settings window -----------------------------------

pub const Entry = struct {
    /// id, like "kokoro-82m-q8_0" (models) or "ef_dora" (voices).
    id: []const u8,
    /// What the row shows.
    label: []const u8,
    /// Voices: the espeak language they read ("" for models).
    lang: []const u8 = "",
    note: []const u8 = "",
    size: u64 = 0,
    /// The bytes of a leftover partial download, 0 when there isn't one.
    partial: u64 = 0,
    downloaded: bool = false,
};

pub const CatalogInfo = struct {
    models: []Entry,
    voices: []Entry,
    /// The phoneme data the engine reads (env, app dir, or the system).
    espeak_ready: bool,
    /// Where it was found, for the Settings row's subtitle ("" when not).
    espeak_source: []const u8,
    /// The settings phase name (a download may be running for the menu).
    phase: []const u8,
};

/// What Settings → Voices lists: the two models, the curated voices, and
/// whether the phoneme data is there. One arena allocation.
pub fn listCatalog(arena: std.mem.Allocator, env: *const std.process.Environ.Map, st: State) !CatalogInfo {
    var models_list: std.ArrayList(Entry) = .empty;
    var voices_list: std.ArrayList(Entry) = .empty;
    const d = dirs(arena, env);
    for (models) |m| {
        const installed = if (d) |dirs_| modelFile(arena, dirs_, m.file) != null else false;
        var partial: u64 = 0;
        if (d) |dirs_| {
            const part_name = std.fmt.allocPrint(arena, "{s}.part", .{m.file}) catch continue;
            const part_path = std.fs.path.join(arena, &.{ dirs_.root, part_name }) catch continue;
            const st_ = std.Io.Dir.cwd().statFile(io, part_path, .{}) catch null;
            if (st_) |stat| partial = stat.size;
        }
        try models_list.append(arena, .{ .id = m.id, .label = m.name, .note = m.note, .size = m.size, .partial = partial, .downloaded = installed });
    }
    for (voices) |v| {
        const installed = if (d) |dirs_| voiceFile(arena, dirs_, v.id) != null else false;
        try voices_list.append(arena, .{ .id = v.id, .label = v.label, .lang = v.lang, .note = "", .size = v.size, .downloaded = installed });
    }
    var src: []const u8 = "";
    if (espeakDataDir(arena, env, d)) |dir| {
        src = dir;
    }
    return .{
        .models = models_list.items,
        .voices = voices_list.items,
        .espeak_ready = src.len > 0,
        .espeak_source = src,
        .phase = @tagName(st.phase),
    };
}

/// Delete a model file.
pub fn deleteModelIo(env: *const std.process.Environ.Map, id: []const u8, arena: std.mem.Allocator) !void {
    const m = findModel(id) orelse return error.UnknownModel;
    const d = dirs(arena, env) orelse return error.NoDataDir;
    const path = std.fs.path.join(arena, &.{ d.root, m.file }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // The engine holds it: drop the context so the next speak starts clean.
    engine_lock.lockUncancelable(io);
    defer engine_lock.unlock(io);
    if (engine) |ctx| {
        if (std.mem.eql(u8, engine_model_file, m.file)) {
            oriel.kokoro.free(ctx);
            engine = null;
        }
    }
}

// ---- tests ----------------------------------------------------------------------------------

test "guessLanguage: the obvious cases" {
    try std.testing.expectEqualStrings("es", guessLanguage("El coche rojo avanza por la ciudad, y las campanas suenan a lejos."));
    try std.testing.expectEqualStrings("en-us", guessLanguage("The committee reviews the design every quarter."));
    try std.testing.expectEqualStrings("es", guessLanguage("¿Cómo está la señal?"));
    try std.testing.expectEqualStrings("zh", guessLanguage("今天天气很好。"));
    try std.testing.expectEqualStrings("ja", guessLanguage("今日はとても良い天気です"));
}
