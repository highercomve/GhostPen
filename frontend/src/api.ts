// Wrappers over the Zig commands (src/main.zig). The command names, arguments
// and results are the same as the Tauri version's, so the components didn't
// change. The types below mirror the Zig structs (src/oriel.ts, generated
// from them, has the exact ones).
import { orielWindow } from "./oriel";
import { listen } from "./events";

const invoke = <T>(cmd: string, args?: unknown): Promise<T> => window.oriel.invoke(cmd, args ?? null) as Promise<T>;

// ---- types (mirror the Rust DTOs) ----------------------------------------------------

export interface Profile {
  id: string;
  name: string;
  /** "openai" (an OpenAI-compatible endpoint) or "local" (built-in: GhostPen runs the model itself). */
  provider?: "openai" | "local";
  baseUrl: string;
  apiKey: string;
  model: string;
  temperature: number;
}

export interface CustomAction {
  id: string;
  label: string;
  prompt: string;
  model: string; // "" = use active profile's model
}

export interface CaptionsSettings {
  model: string;
  language: string;
  whisperTranslate: boolean;
  aiTranslate: boolean;
  targetLang: string;
  chunkSeconds: number;
  device: string;
  fontSize: number;
}

export interface OcrSettings {
  maxDimension: number;
  systemPrompt: string;
  modelOverride: string;
}

export interface Settings {
  hotkey: string;
  dictationHotkey: string;
  captionsHotkey: string;
  activeProfileId: string;
  profiles: Profile[];
  forceSynthetic: boolean;
  restoreDelayMs: number;
  /** After a menu action: paste over the selection, or show it in the menu. */
  afterAction?: "paste" | "show";
  customActions: CustomAction[];
  ocr: OcrSettings;
  captions: CaptionsSettings;
  dictation: DictationSettings;
  localLlm: LocalLlmSettings;
  /** Where the model & speech service listens (other local apps). */
  server?: ServerSettings;
  /** Check for updates in the background and install them where possible. */
  autoUpdate: boolean;
}

/** The model & speech service (built-in models and transcription, one endpoint). */
export interface ServerSettings {
  /** 127.0.0.1 = this machine only; 0.0.0.0 = reachable from the network. */
  host: string;
  port: number;
  /** Context window (tokens) for other apps' chat requests; 0 = the built-in model's setting. */
  ctxTokens?: number;
}

/** The built-in runner ("Built-in" profiles). */
export interface LocalLlmSettings {
  ctxTokens: number;
  gpu: boolean;
  /** MoE models: share of expert weights kept in system RAM, % of blocks (0 = all on the GPU). */
  moePct: number;
  idleMinutes: number;
}

export const isLocal = (p: Profile | undefined) => p?.provider === "local";

export type SelectionInfo =
  | { kind: "empty" }
  | { kind: "text"; text: string }
  | { kind: "image"; preview: string; width: number; height: number };

export interface CaptionsStatus {
  available: boolean;
  running: boolean;
  model_ready: boolean;
  model: string;
  /** Whether AI translation is currently on (mirrors settings.captions.aiTranslate). */
  translate: boolean;
  /** Target language for AI translation, for the overlay toggle label. */
  target_lang: string;
}

/** Payload of the `ghostpen://caption` event. */
export interface Caption {
  text: string;
  translated: boolean;
}

export interface Status {
  session: string;
  clipboard_backend: string;
  input_available: boolean;
  manual_mode: boolean;
  active_profile: string;
  active_model: string;
}

export interface ProcessResult {
  output: string;
  pasted: boolean;
  manual: boolean;
  /** Shown in the menu instead of pasted (Shift+action, or Settings). */
  shown?: boolean;
}

// ---- command wrappers ----------------------------------------------------------------

export const getSettings = () => invoke<Settings>("get_settings");
export const saveSettings = (settings: Settings) =>
  invoke<void>("save_settings", { settings });
export const fetchModels = (baseUrl: string, apiKey: string) =>
  invoke<string[]>("fetch_models", { baseUrl, apiKey });
export const getStatus = () => invoke<Status>("get_status");
export const getSelection = () => invoke<SelectionInfo>("get_selection");
export const extractImageText = () => invoke<string>("extract_image_text");
export const copyText = (text: string) => invoke<void>("copy_text", { text });
/** Paste a result that was shown (not pasted) in the menu: clipboard + Ctrl+V into the app underneath. */
export const pasteResult = (text: string) => invoke<ProcessResult>("paste_result", { text });

// ---- built-in voice (oriel.tts, Kokoro) ------------------------------------------------

/** What a reading is doing: oriel.tts's "tts:state" ("loading" shows as
 *  "generating"), GhostPen's "downloading" before a first reading, and the
 *  download's progress (0–1) from "tts:download". */
export interface TtsState {
  phase: "idle" | "downloading" | "generating" | "playing" | "error";
  message: string;
  progress: number;
  voice: string;
}
interface TtsStateEvent { phase: string; message: string; voice: string }
/** Payload of "tts:download" (`done_mb == total_mb` at the end). */
export interface TtsDownload { id: string; done_mb: number; total_mb: number }

const voicePhase = (p: string): TtsState["phase"] =>
  p === "loading" ? "generating" : (["idle", "downloading", "generating", "playing", "error"].includes(p) ? p : "idle") as TtsState["phase"];
export const toTtsState = (s: TtsStateEvent, progress = 0): TtsState => ({ phase: voicePhase(s.phase), message: s.message, voice: s.voice, progress });

/** Follow the voice: `cb` gets every state change and download step. */
export function listenVoice(cb: (s: TtsState) => void): Promise<() => void> {
  let last: TtsState = { phase: "idle", message: "", progress: 0, voice: "" };
  const unState = listen<TtsStateEvent>("tts:state", (e) => cb((last = toTtsState(e.payload))));
  const unDownload = listen<TtsDownload>("tts:download", (e) => {
    if (last.phase !== "downloading" || e.payload.total_mb <= 0) return;
    cb((last = { ...last, progress: Math.min(1, e.payload.done_mb / e.payload.total_mb) }));
  });
  return Promise.all([unState, unDownload]).then(([a, b]) => () => { a(); b(); });
}

export const ttsState = () => invoke<TtsStateEvent>("tts_state").then((s) => toTtsState(s));
/** Load the voice ahead of a reading (nothing when it isn't downloaded). */
export const ttsWarmUp = (lang = "") => invoke<void>("tts_warm_up", { lang });
/** Settings → Voices: the models, voices, phoneme data and where it runs. */
export const ttsCatalog = () => invoke<TtsCatalog>("tts_catalog");
/** A model or voice; resolves when it's in place, progress as "tts:download". */
export const ttsDownload = (id: string) => invoke<void>("tts_download", { id });
export const ttsDelete = (id: string) => invoke<void>("tts_delete", { id });

export interface TtsCatalogEntry {
  id: string;
  label: string;
  /** Voices: the espeak language they read ("" for models). */
  lang?: string;
  note?: string;
  size: number;
  downloaded: boolean;
}
export interface TtsCatalog {
  models: TtsCatalogEntry[];
  voices: TtsCatalogEntry[];
  espeak_ready: boolean;
  espeak_source: string;
  /** "CPU", "Vulkan0", "CUDA0"… (the loaded model's, else the GPU ggml found). */
  backend: string;
  gpu: string | null;
  /** The model or voice downloading now, "" when none. */
  downloading: string;
  phase: string;
}
/** Read text through the built-in voice (`lang`: an espeak language like "en-us"
 *  or a translate target like "French"; a second call replaces the running one). */
export const ttsSpeak = (text: string, lang = "", voice = "", model = "") =>
  invoke<void>("tts_speak", { text, lang, voice, model });
export const ttsStop = () => invoke<void>("tts_stop");
export type Level = "subtle" | "balanced" | "strong";
export const LEVELS: Level[] = ["subtle", "balanced", "strong"];

export const processAiAction = (action: string, targetLang: string | null, level: Level, show = false) =>
  invoke<ProcessResult>("process_ai_action", { action, targetLang, level, show });
/** Freeform instruction (menu prompt bar) applied to the selection, pasted back like an action. */
export const processAiCustom = (instruction: string, show = false) =>
  invoke<ProcessResult>("process_ai_custom", { instruction, show });
/** Reads the URL, summarizes it and opens the summary window (the answer streams there).
 *  `level` is the summary's depth (web_page.Level): "brief", "standard" or "detailed". */
export const summarizeLink = (url: string, level?: string) => invoke<void>("summarize_link", { url, level });
/** The summarize-link flow's state: for the summary window's page to pick up what
 * it missed while loading (its listeners attach after the first events). */
export interface SummaryState {
  state: string;
  title: string;
  chars: number;
  message: string;
  markdown: string;
  /** The page's readable text: the read-aloud's whole-page source. */
  page_text?: string;
}
export const summaryState = () => invoke<SummaryState>("summary_state");
/** The clipboard's text, when there is any (the summary window's prefill). */
export const clipboardText = () => invoke<string>("clipboard_text");
/** Playground: transform text directly, no clipboard involved. */
export const processText = (action: string, targetLang: string | null, level: Level, text: string) =>
  invoke<string>("process_text", { action, targetLang, level, text });
/** Streaming variant: emits ghostpen://chunk / ::done / ::error events. */
export const processTextStream = (action: string, targetLang: string | null, level: Level, text: string) =>
  invoke<void>("process_text_stream", { action, targetLang, level, text });
export const openPlayground = () => invoke<void>("open_playground");
/** Hide the window this page runs in (Oriel: the window API, no command). */
export const hideWindow = () => orielWindow.current().hide();
/** Close the menu without pasting: the clipboard gets back what it held before the trigger. */
export const dismissMenu = () => {
  invoke<void>("menu_dismissed").catch(() => {});
  return hideWindow();
};
export const openSettings = () => invoke<void>("open_settings");

// ---- captions (ADR-008) --------------------------------------------------------------

export const openCaptions = () => invoke<void>("open_captions");
export const captionsStatus = () => invoke<CaptionsStatus>("captions_status");
/** An audio source: `name` goes in the settings, `label` is shown. */
export interface AudioDevice {
  name: string;
  label: string;
  /** System audio (what the speakers play), not a microphone. */
  monitor: boolean;
}

export const captionsListDevices = () => invoke<AudioDevice[]>("captions_list_devices");
/** Start capturing + transcribing; resolves to the capture device name. */
export const captionsStart = () => invoke<string>("captions_start");
export const captionsStop = () => invoke<void>("captions_stop");
export const captionsSetClickThrough = (enable: boolean) =>
  invoke<void>("captions_set_click_through", { enable });
/** Toggle AI translation live (persists to settings; takes effect on the next chunk). */
export const captionsSetTranslate = (enable: boolean) =>
  invoke<void>("captions_set_translate", { enable });
/** Download the configured (or a specific) whisper model. May take a while (~140MB for base). */
export const captionsDownloadModel = (model?: string) =>
  invoke<void>("captions_download_model", { model: model ?? null });

// ---- dictation (ADR-009) --------------------------------------------------------------

/** Dictation shares the whisper model with captions (`settings.captions.model`). */
export interface DictationSettings {
  language: string;
  proofread: boolean;
  device: string;
  /** Paste at the cursor when finished (off: copy only). */
  paste?: boolean;
}

export interface DictationStatus {
  model_ready: boolean;
  model: string;
  proofread: boolean;
  /** Spoken language ("auto" or an ISO code) — mirrors settings.dictation.language. */
  language: string;
}

/** Payload of the `ghostpen://dictation` event. */
export interface DictationUpdate {
  text: string;
  /** listening | transcribing | proofreading | done | cancelled | error */
  state: string;
}

/** Microphone candidates for the Settings picker (no monitor/loopback sources). */
export const dictationListDevices = () => invoke<AudioDevice[]>("dictation_list_devices");
export const dictationStatus = () => invoke<DictationStatus>("dictation_status");
/** Start listening; resolves to the capture device name. */
export const dictationStart = () => invoke<string>("dictation_start");
/** Stop & finalize (transcribe → proofread → paste); progress streams via events. */
export const dictationStop = () => invoke<void>("dictation_stop");
/** Discard the captured audio and hide the overlay. */
export const dictationCancel = () => invoke<void>("dictation_cancel");
/** Set the spoken language (persists; a running session picks it up on the next pass). */
export const dictationSetLanguage = (language: string) =>
  invoke<void>("dictation_set_language", { language });
/** Toggle AI proofread live (persists; a running session picks it up before the AI call). */
export const dictationSetProofread = (enabled: boolean) =>
  invoke<void>("dictation_set_proofread", { enabled });

// ---- speech (whisper) models: Settings → Speech models ---------------------------------

export interface WhisperModelState {
  id: string;
  size: number;
  speed: number;
  accuracy: number;
  note: string;
  /** Where it is ("" = not downloaded). */
  path: string;
  /** Found in another app's folder (reused; not removable here). */
  external: boolean;
  /** Bytes of an interrupted download (resumable). */
  partial: number;
}
export interface WhisperLocalFile {
  id: string;
  path: string;
  size: number;
  external: boolean;
}
export interface WhisperStatus {
  status: { models: WhisperModelState[]; others: WhisperLocalFile[] };
  downloading: boolean;
}
export const whisperModelsStatus = () => invoke<WhisperStatus>("whisper_models_status");
/** Resolves when done; progress arrives as `ghostpen://whisper-download` (an LlmProgress). */
export const whisperDownloadModel = (id: string) => invoke<void>("whisper_download_model", { id });
export const whisperCancelDownload = () => invoke<void>("whisper_cancel_download");
export const whisperDeleteModel = (id: string) => invoke<void>("whisper_delete_model", { id });

/** Compact bar meter like "▰▰▰▱▱" for a 1–5 score. */
export const scoreMeter = (n: number) => "▰".repeat(n) + "▱".repeat(5 - n);

// Whisper source-language codes (subset; "auto" detects).
export const CAPTION_LANGUAGES = [
  "auto", "en", "es", "fr", "de", "it", "pt", "nl", "zh", "ja", "ko", "ru", "ar",
];

// ---- presets (Settings UI starting points) -------------------------------------------

export interface Preset {
  name: string;
  baseUrl: string;
  keyNeeded: boolean;
  exampleModel: string;
}

export const PRESETS: Preset[] = [
  { name: "Ollama (local)", baseUrl: "http://localhost:11434/v1", keyNeeded: false, exampleModel: "gemma4:e4b" },
  { name: "LM Studio", baseUrl: "http://localhost:1234/v1", keyNeeded: false, exampleModel: "" },
  { name: "OpenAI", baseUrl: "https://api.openai.com/v1", keyNeeded: true, exampleModel: "gpt-4o-mini" },
  { name: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", keyNeeded: true, exampleModel: "google/gemma-3-27b-it" },
  { name: "Groq", baseUrl: "https://api.groq.com/openai/v1", keyNeeded: true, exampleModel: "llama-3.3-70b-versatile" },
  { name: "Custom", baseUrl: "", keyNeeded: false, exampleModel: "" },
];

export const TRANSLATE_LANGUAGES = [
  "English", "Spanish", "French", "German", "Italian", "Portuguese",
  "Dutch", "Chinese", "Japanese", "Korean", "Russian", "Arabic",
];

// ---- built-in models (GhostPen runs them) -----------------------------------------------------

export interface LlmModel {
  id: string;
  name: string;
  file: string;
  size: number;
  speed: number;
  quality: number;
  note: string;
  /** Where it is ("" = not downloaded). */
  path: string;
  /** Found in another app's folder (LM Studio, GhostReel): reused, not removable here. */
  external: boolean;
  /** Bytes of an interrupted download. */
  partial: number;
  /** It has an image projector (mmproj) to download. */
  vision_available: boolean;
  projector_size: number;
  /** The projector is there: it reads images (Extract Text). */
  vision: boolean;
  /** The context the model was trained for (0 = unknown): the window's maximum. */
  ctx_max: number;
}

/** A GGUF found on disk that isn't in the catalog (id = "file:<path>"). */
export interface LlmLocalFile {
  id: string;
  name: string;
  path: string;
  size: number;
  /** An mmproj next to it: it reads images. */
  vision: boolean;
  /** The context the model was trained for (0 = unknown). */
  ctx_max: number;
}

export interface LlmStatus {
  status: { dir: string; models: LlmModel[]; others: LlmLocalFile[] };
  downloading: boolean;
  loaded: boolean;
}

/** Payload of `ghostpen://llm-download`. */
export interface LlmProgress {
  id: string;
  state: "downloading" | "verifying" | "done" | "cancelled" | "error";
  done: number;
  total: number;
  message: string;
}

/** Stop the running request (built-in model only). */
export const cancelAi = () => invoke<void>("cancel_ai");
export const llmModelsStatus = () => invoke<LlmStatus>("llm_models_status");
/** Resolves when the download finishes; progress arrives as `ghostpen://llm-download`. */
export const llmDownloadModel = (id: string) => invoke<void>("llm_download_model", { id });
export const llmCancelDownload = () => invoke<void>("llm_cancel_download");
export const llmDeleteModel = (id: string) => invoke<void>("llm_delete_model", { id });
/** Free the loaded model's memory now. */
export const llmUnload = () => invoke<void>("llm_unload");

export const formatBytes = (n: number) =>
  n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(n / 1e6))} MB`;

/** The paste shortcut as the user types it: ⌘V on macOS, Ctrl+V elsewhere. */
export const PASTE_KEYS = /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent) ? "⌘V" : "Ctrl+V";

// ---- about & updates ------------------------------------------------------------------

export interface AppInfo {
  version: string;
  /** windows | appimage | macos_app | package | source */
  install_kind: string;
  /** GhostPen can replace itself (else: package manager or a new download). */
  can_install: boolean;
  releases_url: string;
  /** An update is installed and applies on restart. */
  installed_version: string | null;
}

export interface UpdateCheck {
  available: boolean;
  version: string | null;
  can_install: boolean;
  installed: boolean;
  releases_url: string;
}

export interface UpdateProgress {
  downloaded: number;
  total: number | null;
}

export const appInfo = () => invoke<AppInfo>("app_info");
export const updateCheck = () => invoke<UpdateCheck>("update_check");
/** Download and install; progress arrives as `ghostpen://update-progress`. */
export const updateInstall = () => invoke<void>("update_install");
export const updateRestart = () => invoke<void>("update_restart");
