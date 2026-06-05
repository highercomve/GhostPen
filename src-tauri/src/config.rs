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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
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
}

fn default_hotkey() -> String {
    "Ctrl+Shift+A".into()
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
                Profile {
                    // LM Studio's OpenAI-compatible server (default port 1234). Model id is left
                    // blank — LM Studio model ids depend on what's loaded; pick via "Fetch models".
                    id: "lmstudio-local".into(),
                    name: "LM Studio".into(),
                    base_url: "http://localhost:1234/v1".into(),
                    api_key: String::new(),
                    model: String::new(),
                    temperature: 0.2,
                },
            ],
            force_synthetic: false,
            restore_delay_ms: default_restore_delay(),
            custom_actions: Vec::new(),
        }
    }
}
