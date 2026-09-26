// Wrappers over the Zig commands (src/main.zig). The command names, arguments
// and results are the same as the Tauri version's, so the components didn't
// change. The types below mirror the Zig structs (src/oriel.ts, generated
// from them, has the exact ones).
import { orielWindow } from "./oriel";

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
  customActions: CustomAction[];
  ocr: OcrSettings;
  captions: CaptionsSettings;
  dictation: DictationSettings;
  localLlm: LocalLlmSettings;
  /** Check for updates in the background and install them where possible. */
  autoUpdate: boolean;
}

/** The built-in runner ("Built-in" profiles). */
export interface LocalLlmSettings {
  ctxTokens: number;
  gpu: boolean;
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
export type Level = "subtle" | "balanced" | "strong";
export const LEVELS: Level[] = ["subtle", "balanced", "strong"];

export const processAiAction = (action: string, targetLang: string | null, level: Level) =>
  invoke<ProcessResult>("process_ai_action", { action, targetLang, level });
/** Freeform instruction (menu prompt bar) applied to the selection, pasted back like an action. */
export const processAiCustom = (instruction: string) =>
  invoke<ProcessResult>("process_ai_custom", { instruction });
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
export const captionsListDevices = () => invoke<string[]>("captions_list_devices");
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
export const dictationListDevices = () => invoke<string[]>("dictation_list_devices");
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

// Whisper models offered in the UI (ggml-{id}.bin on Hugging Face). Ordered fastest →
// most accurate. `.en` variants are English-only but a bit faster/more accurate for English.
// `speed`/`accuracy` are relative 1–5 (5 = best) for the little meter in the UI.
export interface WhisperModelInfo {
  id: string;
  size: string;
  speed: number;
  accuracy: number;
  note: string;
}
export const WHISPER_MODELS: WhisperModelInfo[] = [
  { id: "tiny",      size: "~75 MB",  speed: 5, accuracy: 1, note: "fastest, lowest accuracy" },
  { id: "tiny.en",   size: "~75 MB",  speed: 5, accuracy: 2, note: "fastest, English-only" },
  { id: "base",      size: "~142 MB", speed: 4, accuracy: 2, note: "fast, basic accuracy" },
  { id: "base.en",   size: "~142 MB", speed: 4, accuracy: 3, note: "fast, English-only" },
  { id: "small",     size: "~466 MB", speed: 3, accuracy: 4, note: "balanced — sweet spot on a GPU" },
  { id: "small.en",  size: "~466 MB", speed: 3, accuracy: 4, note: "balanced, English-only" },
  { id: "medium",    size: "~1.5 GB", speed: 2, accuracy: 5, note: "most accurate, heaviest" },
  { id: "medium.en", size: "~1.5 GB", speed: 2, accuracy: 5, note: "most accurate, English-only" },
];

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
}

/** A GGUF found on disk that isn't in the catalog (id = "file:<path>"). */
export interface LlmLocalFile {
  id: string;
  name: string;
  path: string;
  size: number;
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
