import { invoke } from "@tauri-apps/api/core";

// ---- types (mirror the Rust DTOs) ----------------------------------------------------

export interface Profile {
  id: string;
  name: string;
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

export interface Settings {
  hotkey: string;
  activeProfileId: string;
  profiles: Profile[];
  forceSynthetic: boolean;
  restoreDelayMs: number;
  customActions: CustomAction[];
  captions: CaptionsSettings;
  dictation: DictationSettings;
}

export interface CaptionsStatus {
  available: boolean;
  running: boolean;
  device: string | null;
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
  use_synthetic: boolean;
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
export const getSelection = () => invoke<string>("get_selection");
export type Level = "subtle" | "balanced" | "strong";

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
export const showMenu = () => invoke<void>("show_menu");
export const hideWindow = () => invoke<void>("hide_window");
export const openSettings = () => invoke<void>("open_settings");
export const closeSettings = () => invoke<void>("close_settings");

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
  available: boolean;
  running: boolean;
  model_ready: boolean;
  model: string;
  proofread: boolean;
  /** Spoken language ("auto" or an ISO code) — mirrors settings.dictation.language. */
  language: string;
  device: string | null;
}

/** Payload of the `ghostpen://dictation` event. */
export interface DictationUpdate {
  text: string;
  /** listening | transcribing | proofreading | done | cancelled | error */
  state: string;
  pasted: boolean;
  manual: boolean;
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
