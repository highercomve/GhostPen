//! Live system-audio captions (ADR-008).
//!
//! Pipeline: **loopback capture (cpal)** → **on-device transcription (whisper.cpp)** →
//! *optional* **AI translation (the active OpenAI-compatible profile)** → a transparent,
//! click-through **captions overlay window**. Subtitles for any system audio — meetings,
//! videos, podcasts — with nothing but the optional translation step leaving the machine.
//!
//! The heavy backend (cpal + whisper-rs) is gated behind the `captions` Cargo feature so the
//! default build adds no new system dependencies. When compiled without it, the commands and
//! the overlay still exist but `start` reports that the build lacks captions support — the app
//! degrades, it never crashes (Critical rule 3).

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(feature = "captions")]
pub mod audio;
pub mod model;
#[cfg(feature = "captions")]
pub mod pool;
#[cfg(feature = "captions")]
pub mod server;
#[cfg(feature = "captions")]
pub mod transcribe;

/// Payload for the `ghostpen://caption` event consumed by the overlay UI.
#[derive(Clone, Serialize)]
pub struct Caption {
    /// The text to display (translated if AI translation is on, otherwise the transcript).
    pub text: String,
    /// True when `text` was produced by the AI translation step.
    pub translated: bool,
}

/// Snapshot of the captions subsystem for the UI (only what the overlay reads).
#[derive(Clone, Serialize)]
pub struct CaptionsStatus {
    /// Whether this build includes captions support (the `captions` feature).
    pub available: bool,
    pub running: bool,
    /// Whether the configured whisper model is downloaded.
    pub model_ready: bool,
    pub model: String,
    /// Whether AI translation is currently on (mirrors `settings.captions.ai_translate`).
    pub translate: bool,
    /// Target language for AI translation, for the overlay's toggle label (e.g. "Spanish").
    pub target_lang: String,
}

/// Owns the running capture + transcription worker. Stored in `AppState`.
#[derive(Default)]
pub struct CaptionsManager {
    running: AtomicBool,
    /// Live "AI-translate" flag the transcription worker reads on every chunk, so the overlay
    /// can flip translation on/off mid-session without restarting capture. Mirrors
    /// `settings.captions.ai_translate`: set from settings at `start`, updated by
    /// `set_translate` (the `captions_set_translate` command also persists it to settings).
    translate: std::sync::Arc<AtomicBool>,
    /// One resident whisper model shared by captions, dictation, and the HTTP
    /// server — loaded once, never stacked. See `pool::ModelPool`.
    #[cfg(feature = "captions")]
    pool: std::sync::Arc<pool::ModelPool>,
    #[cfg(feature = "captions")]
    session: std::sync::Mutex<Option<RunningSession>>,
}

#[cfg(feature = "captions")]
struct RunningSession {
    capture: audio::Capture,
    stop: std::sync::Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}

#[cfg(feature = "captions")]
impl RunningSession {
    fn shutdown(mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.capture.stop();
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
    }
}

impl CaptionsManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// True when this build can actually run captions (the `captions` feature is compiled in).
    pub fn available(&self) -> bool {
        cfg!(feature = "captions")
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// Flip AI translation live; the worker reads this on its next chunk. Persisting the
    /// choice to `settings` is the caller's responsibility (see `captions_set_translate`).
    pub fn set_translate(&self, enable: bool) {
        self.translate.store(enable, Ordering::SeqCst);
    }

    pub fn status(&self, settings: &crate::config::Settings) -> CaptionsStatus {
        let model = settings.captions.model.clone();
        CaptionsStatus {
            available: self.available(),
            running: self.is_running(),
            model_ready: model::is_downloaded(&model),
            model,
            translate: settings.captions.ai_translate,
            target_lang: settings.captions.target_lang.clone(),
        }
    }
}

#[cfg(feature = "captions")]
impl CaptionsManager {
    /// The shared whisper model pool — handed to the dictation workers and the
    /// HTTP server so every path transcribes through one resident model.
    pub fn pool(&self) -> std::sync::Arc<pool::ModelPool> {
        self.pool.clone()
    }

    /// Start capturing + transcribing. Returns the capture device name on success.
    pub fn start(
        &self,
        app: &tauri::AppHandle,
        settings: &crate::config::Settings,
    ) -> Result<String, String> {
        if self.is_running() {
            return Err("Captions are already running".into());
        }
        let cfg = settings.captions.clone();

        // The model must be present; the UI downloads it first via `captions_download_model`.
        let model_path = model::model_path(&cfg.model)?;
        if !model_path.exists() {
            return Err(format!(
                "Whisper model \"{}\" isn't downloaded yet. Download it first.",
                cfg.model
            ));
        }
        // Load (or reuse) the one shared model; the worker transcribes through it.
        self.pool.ensure(&cfg.model)?;
        let pool = self.pool.clone();

        let buffer = audio::SampleBuffer::default();
        let capture = audio::start(&cfg.device, buffer.clone())?;
        let device = capture.device_name.clone();

        let stop = std::sync::Arc::new(AtomicBool::new(false));
        let stop_worker = stop.clone();
        let app_worker = app.clone();
        // Seed the live translate flag from settings; the overlay can flip it mid-session.
        self.translate.store(cfg.ai_translate, Ordering::SeqCst);
        let translate_flag = self.translate.clone();
        // The active profile is captured once for the session's AI translation.
        let profile = settings.active().cloned();

        let chunk_samples = ((cfg.chunk_seconds.max(1.0)) * audio::TARGET_RATE as f32) as usize;

        let worker = std::thread::Builder::new()
            .name("ghostpen-captions".into())
            .spawn(move || {
                tracing::info!("captions worker started ({} samples/chunk)", chunk_samples);
                while !stop_worker.load(Ordering::SeqCst) {
                    if buffer.len() < chunk_samples {
                        std::thread::sleep(std::time::Duration::from_millis(200));
                        continue;
                    }
                    let samples = buffer.drain();
                    if samples.is_empty() {
                        continue;
                    }
                    let text =
                        match pool.transcribe(&cfg.model, &samples, &cfg.language, cfg.whisper_translate)
                        {
                            Ok(t) => t,
                            Err(e) => {
                                tracing::warn!("transcription error: {e}");
                                let _ = emit_error(&app_worker, &e);
                                continue;
                            }
                        };
                    if text.trim().is_empty() {
                        continue;
                    }

                    // Optional AI translation for non-English targets — read live so the
                    // overlay's toggle takes effect on the very next chunk.
                    let (display, translated) = if translate_flag.load(Ordering::SeqCst) {
                        match translate_text(profile.as_ref(), &cfg.target_lang, &text) {
                            Ok(t) => (t, true),
                            Err(e) => {
                                tracing::warn!("caption translation error: {e}");
                                (text.clone(), false)
                            }
                        }
                    } else {
                        (text.clone(), false)
                    };

                    let _ = emit_caption(&app_worker, &display, translated);
                }
                tracing::info!("captions worker stopped");
            })
            .map_err(|e| format!("failed to spawn captions worker: {e}"))?;

        *self.session.lock().map_err(|_| "captions state poisoned")? = Some(RunningSession {
            capture,
            stop,
            worker: Some(worker),
        });
        self.running.store(true, Ordering::SeqCst);
        tracing::info!("captions started on device {device}");
        Ok(device)
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        let session = self.session.lock().ok().and_then(|mut g| g.take());
        if let Some(s) = session {
            s.shutdown();
        }
    }
}

#[cfg(not(feature = "captions"))]
impl CaptionsManager {
    pub fn start(
        &self,
        _app: &tauri::AppHandle,
        _settings: &crate::config::Settings,
    ) -> Result<String, String> {
        Err("This build was compiled without captions support. Rebuild with `--features captions`."
            .into())
    }

    pub fn stop(&self) {}
}

// ---- helpers (feature-gated; reference Tauri/AI only when captions are built) ----------

#[cfg(feature = "captions")]
fn emit_caption(app: &tauri::AppHandle, text: &str, translated: bool) -> Result<(), String> {
    use tauri::Emitter;
    app.emit(
        "ghostpen://caption",
        Caption {
            text: text.to_string(),
            translated,
        },
    )
    .map_err(|e| e.to_string())
}

#[cfg(feature = "captions")]
fn emit_error(app: &tauri::AppHandle, message: &str) -> Result<(), String> {
    use tauri::Emitter;
    app.emit("ghostpen://caption-error", message.to_string())
        .map_err(|e| e.to_string())
}

/// Translate a transcript fragment via the active AI profile (blocking on Tauri's runtime).
#[cfg(feature = "captions")]
fn translate_text(
    profile: Option<&crate::config::Profile>,
    target_lang: &str,
    text: &str,
) -> Result<String, String> {
    let profile = profile.ok_or("No active AI profile for translation")?;
    let system = crate::ai::system_prompt("translate", Some(target_lang), None)?;
    let profile = profile.clone();
    let text = text.to_string();
    tauri::async_runtime::block_on(async move {
        crate::ai::run_completion(&profile, &system, &crate::ai::UserContent::Text(text)).await
    })
}
