//! Shared whisper model — one resident context for every transcription path.
//!
//! The live captions worker, voice dictation, and the optional HTTP server all
//! transcribe through this pool instead of each loading its own model. Loading a
//! model costs VRAM + time, and running two inferences on one whisper/CUDA
//! context concurrently is not safe — so the pool keeps a *single* loaded model
//! and serializes inference behind a mutex. Callers take turns; we never stack
//! two copies of the model in GPU memory.
//!
//! All three paths use `settings.captions.model`, so the held model is shared
//! rather than thrashing. If a caller asks for a different model, the pool drops
//! the old one and loads the new (still only ever one resident).

#![cfg(feature = "captions")]

use std::sync::Mutex;

use super::model;
use super::transcribe::Transcriber;

/// One loaded whisper model, swapped only when a different model is requested.
#[derive(Default)]
pub struct ModelPool {
    /// `(model_name, loaded model)`. `None` until first use.
    slot: Mutex<Option<(String, Transcriber)>>,
}

impl ModelPool {
    pub fn new() -> Self {
        Self::default()
    }

    /// Pre-load `model_name` so the first real request isn't slow. Reloads if a
    /// different model is currently held.
    pub fn ensure(&self, model_name: &str) -> Result<(), String> {
        let mut slot = self.slot.lock().map_err(|_| "model pool poisoned".to_string())?;
        load_if_needed(&mut slot, model_name)
    }

    /// Transcribe on the shared model, loading/reloading on demand. Serialized,
    /// so the live dictation loop and a server request never touch the CUDA
    /// context at the same time.
    pub fn transcribe(
        &self,
        model_name: &str,
        samples: &[f32],
        language: &str,
        translate: bool,
    ) -> Result<String, String> {
        let mut slot = self.slot.lock().map_err(|_| "model pool poisoned".to_string())?;
        load_if_needed(&mut slot, model_name)?;
        // Safe: load_if_needed leaves `Some` on success.
        let (_, transcriber) = slot.as_mut().expect("model loaded");
        transcriber.transcribe(samples, language, translate)
    }

    /// Whether a model is currently resident.
    pub fn is_loaded(&self) -> bool {
        self.slot.lock().map(|g| g.is_some()).unwrap_or(false)
    }
}

fn load_if_needed(
    slot: &mut Option<(String, Transcriber)>,
    model_name: &str,
) -> Result<(), String> {
    let have = slot.as_ref().map(|(n, _)| n == model_name).unwrap_or(false);
    if have {
        return Ok(());
    }
    let path = model::model_path(model_name)?;
    if !path.exists() {
        return Err(format!(
            "Whisper model \"{model_name}\" isn't downloaded yet. Download it in Settings → Captions."
        ));
    }
    // Drop the old model before loading the new one so only one is ever resident.
    *slot = None;
    *slot = Some((model_name.to_string(), Transcriber::load(&path)?));
    Ok(())
}
