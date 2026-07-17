//! Configuration — the runtime-configurable AI backend (plan §5/§6).
//!
//! Persisted as JSON under `settings.json` via tauri-plugin-store. Rust is the single source
//! of truth (frontend reads/writes through commands), which sidesteps JS↔Rust store staleness.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    #[serde(default, rename = "apiKey")]
    pub api_key: String,
    pub model: String,
    #[serde(default = "default_temp")]
    pub temperature: f32,
}

fn default_temp() -> f32 {
    0.2
}

/// A user-defined action with a custom system prompt and optional per-action model override.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CustomAction {
    pub id: String,
    pub label: String,
    pub prompt: String,
    /// Empty = use the active profile's model.
    #[serde(default)]
    pub model: String,
}

/// Image-text extraction (OCR) settings (ADR-011).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OcrSettings {
    /// Max width/height in px before the image is sent to the model.
    #[serde(default = "default_ocr_max_dim", rename = "maxDimension")]
    pub max_dimension: u32,
    /// Empty = built-in default prompt (so upgrades improve the prompt automatically).
    #[serde(default, rename = "systemPrompt")]
    pub system_prompt: String,
    /// Empty = active profile's model.
    #[serde(default, rename = "modelOverride")]
    pub model_override: String,
}

fn default_ocr_max_dim() -> u32 {
    1024
}

impl Default for OcrSettings {
    fn default() -> Self {
        OcrSettings {
            max_dimension: 1024,
            system_prompt: "".into(),
            model_override: "".into(),
        }
    }
}

/// Live system-audio captions (ADR-008). Defaults are conservative: transcribe-only
/// (no translation), auto source language, the small/fast `base` whisper model.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CaptionsSettings {
    /// Whisper model id → resolves to `ggml-{model}.bin` in the app data dir's `models/`.
    /// e.g. `base`, `base.en`, `small`, `small.en`, `medium`. Smaller = faster, less accurate.
    #[serde(default = "default_caption_model")]
    pub model: String,
    /// Source language: `auto` (detect) or an ISO code (`en`, `es`, `fr`, …).
    #[serde(default = "default_caption_language")]
    pub language: String,
    /// Use Whisper's built-in translate (source → English) — free, but English-only target.
    #[serde(default, rename = "whisperTranslate")]
    pub whisper_translate: bool,
    /// Route the transcript through the active AI profile to translate into `targetLang`.
    /// Use this for non-English targets (Whisper's built-in translate only outputs English).
    #[serde(default, rename = "aiTranslate")]
    pub ai_translate: bool,
    /// Target language for AI translation (when `aiTranslate` is on).
    #[serde(default = "default_caption_target", rename = "targetLang")]
    pub target_lang: String,
    /// Seconds of audio per transcription chunk. Larger = more context/accuracy, more latency.
    #[serde(default = "default_caption_chunk", rename = "chunkSeconds")]
    pub chunk_seconds: f32,
    /// Capture device name substring to match; empty = auto-pick the system-audio loopback.
    #[serde(default)]
    pub device: String,
    /// Caption font size in px (the overlay UI reads this).
    #[serde(default = "default_caption_font", rename = "fontSize")]
    pub font_size: u32,
}

fn default_caption_model() -> String {
    "base".into()
}
fn default_caption_language() -> String {
    "auto".into()
}
fn default_caption_target() -> String {
    "English".into()
}
fn default_caption_chunk() -> f32 {
    5.0
}
fn default_caption_font() -> u32 {
    28
}

impl Default for CaptionsSettings {
    fn default() -> Self {
        CaptionsSettings {
            model: default_caption_model(),
            language: default_caption_language(),
            whisper_translate: false,
            ai_translate: false,
            target_lang: default_caption_target(),
            chunk_seconds: default_caption_chunk(),
            device: String::new(),
            font_size: default_caption_font(),
        }
    }
}

/// Voice dictation (ADR-009): mic → whisper → optional AI proofread → paste in place.
/// Uses the SAME whisper model as captions (`settings.captions.model`) so the model is
/// downloaded and managed once; only the mic/language/proofread knobs are dictation's own.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DictationSettings {
    /// Spoken language: `auto` (detect) or an ISO code (`en`, `es`, …).
    #[serde(default = "default_caption_language")]
    pub language: String,
    /// Run the final transcript through the AI `proofread` action before pasting.
    #[serde(default = "default_true")]
    pub proofread: bool,
    /// Microphone name substring to match; empty = default input device.
    #[serde(default)]
    pub device: String,
}

fn default_true() -> bool {
    true
}

impl Default for DictationSettings {
    fn default() -> Self {
        DictationSettings {
            language: default_caption_language(),
            proofread: true,
            device: String::new(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    /// Global hotkey for the action menu (`--trigger`). Registered in-process on
    /// X11/Windows/macOS; on Wayland it's advisory (bind it in the compositor).
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
    /// Global hotkey for voice dictation (`--voice-input`). Blank = unbound.
    #[serde(default = "default_dictation_hotkey", rename = "dictationHotkey")]
    pub dictation_hotkey: String,
    /// Global hotkey for live captions (`--captions`). Blank = unbound.
    #[serde(default = "default_captions_hotkey", rename = "captionsHotkey")]
    pub captions_hotkey: String,
    #[serde(rename = "activeProfileId")]
    pub active_profile_id: String,
    pub profiles: Vec<Profile>,
    /// Force synthetic input on Wayland (default: manual-copy mode there — ADR-005/007).
    #[serde(default, rename = "forceSynthetic")]
    pub force_synthetic: bool,
    /// Delay before restoring the user's original clipboard after a synthetic paste.
    #[serde(default = "default_restore_delay", rename = "restoreDelayMs")]
    pub restore_delay_ms: u64,
    #[serde(default, rename = "customActions")]
    pub custom_actions: Vec<CustomAction>,
    /// Image-text extraction (OCR) configuration (ADR-011).
    #[serde(default)]
    pub ocr: OcrSettings,
    /// Live system-audio captions configuration (ADR-008).
    #[serde(default)]
    pub captions: CaptionsSettings,
    /// Voice dictation configuration (ADR-009).
    #[serde(default)]
    pub dictation: DictationSettings,
}

fn default_hotkey() -> String {
    "Ctrl+Shift+A".into()
}

fn default_dictation_hotkey() -> String {
    "Ctrl+Shift+D".into()
}

fn default_captions_hotkey() -> String {
    "Ctrl+Shift+L".into()
}

fn default_restore_delay() -> u64 {
    300
}

impl Settings {
    pub fn active(&self) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.id == self.active_profile_id)
    }

    /// First-run defaults: the local Ollama preset running the shipped default model.
    pub fn defaults() -> Self {
        Settings {
            hotkey: default_hotkey(),
            dictation_hotkey: default_dictation_hotkey(),
            captions_hotkey: default_captions_hotkey(),
            active_profile_id: "ollama-local".into(),
            profiles: vec![
                Profile {
                    id: "ollama-local".into(),
                    name: "Ollama (local)".into(),
                    base_url: "http://localhost:11434/v1".into(),
                    api_key: String::new(),
                    model: "gemma4:e4b".into(),
                    temperature: 0.2,
                },
            ],
            force_synthetic: false,
            restore_delay_ms: default_restore_delay(),
            custom_actions: Vec::new(),
            ocr: OcrSettings::default(),
            captions: CaptionsSettings::default(),
            dictation: DictationSettings::default(),
        }
    }
}
