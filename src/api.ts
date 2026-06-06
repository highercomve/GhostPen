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
}

export interface CaptionsStatus {
  available: boolean;
  running: boolean;
  device: string | null;
  model_ready: boolean;
  model: string;
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
/** Download the configured (or a specific) whisper model. May take a while (~140MB for base). */
export const captionsDownloadModel = (model?: string) =>
  invoke<void>("captions_download_model", { model: model ?? null });

// Whisper model ids offered in the UI (ggml-{id}.bin on Hugging Face).
export const WHISPER_MODELS = [
  "tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
];

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
