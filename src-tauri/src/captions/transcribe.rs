//! Local speech-to-text via whisper.cpp / whisper-rs (ADR-008), feature-gated behind `captions`.
//!
//! Runs entirely on-device — audio never leaves the machine for transcription. (Optional AI
//! translation of the transcript is a separate, explicit step in `mod.rs`.)
//!
//! Targets whisper-rs 0.14.

use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// A loaded whisper model + reusable decode state. Created once per captions session and lives
/// on the transcription worker thread (whisper state is single-threaded).
pub struct Transcriber {
    ctx: WhisperContext,
    n_threads: i32,
}

impl Transcriber {
    /// Load a ggml model from disk.
    pub fn load(model_path: &Path) -> Result<Self, String> {
        let path = model_path
            .to_str()
            .ok_or("Model path is not valid UTF-8")?;
        let ctx = WhisperContext::new_with_params(path, WhisperContextParameters::default())
            .map_err(|e| format!("Failed to load whisper model: {e}"))?;
        let n_threads = std::thread::available_parallelism()
            .map(|n| n.get() as i32)
            .unwrap_or(4)
            .min(8);
        Ok(Transcriber { ctx, n_threads })
    }

    /// Transcribe 16 kHz mono f32 samples.
    ///
    /// - `language`: `auto` (detect) or an ISO code (`en`, `es`, …).
    /// - `translate`: Whisper's built-in source→English translation (free; English-only target).
    pub fn transcribe(
        &mut self,
        samples: &[f32],
        language: &str,
        translate: bool,
    ) -> Result<String, String> {
        let mut state = self
            .ctx
            .create_state()
            .map_err(|e| format!("Whisper state error: {e}"))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(self.n_threads);
        // `auto` → let whisper detect; otherwise pin the language.
        let lang = if language.trim().eq_ignore_ascii_case("auto") || language.trim().is_empty() {
            None
        } else {
            Some(language.trim())
        };
        params.set_language(lang);
        params.set_translate(translate);
        // Keep the model quiet — we only want the text, not whisper's stderr chatter.
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);

        state
            .full(params, samples)
            .map_err(|e| format!("Transcription failed: {e}"))?;

        // whisper-rs 0.16: `full_n_segments` returns the count directly, and segment text is
        // read via `get_segment(i).to_str()`.
        let n = state.full_n_segments();
        let mut text = String::new();
        for i in 0..n {
            if let Some(segment) = state.get_segment(i) {
                if let Ok(seg) = segment.to_str() {
                    text.push_str(seg);
                }
            }
        }
        Ok(text.trim().to_string())
    }
}
