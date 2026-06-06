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
pub mod transcribe;

/// Payload for the `ghostpen://caption` event consumed by the overlay UI.
#[derive(Clone, Serialize)]
pub struct Caption {
    /// The text to display (translated if AI translation is on, otherwise the transcript).
    pub text: String,
    /// True when `text` was produced by the AI translation step.
    pub translated: bool,
}

/// Snapshot of the captions subsystem for the UI.
#[derive(Clone, Serialize)]
pub struct CaptionsStatus {
    /// Whether this build includes captions support (the `captions` feature).
    pub available: bool,
    pub running: bool,
    /// Capture device in use while running.
    pub device: Option<String>,
    /// Whether the configured whisper model is downloaded.
    pub model_ready: bool,
    pub model: String,
}

/// Owns the running capture + transcription worker. Stored in `AppState`.
#[derive(Default)]
pub struct CaptionsManager {
    running: AtomicBool,
    #[cfg(feature = "captions")]
    session: std::sync::Mutex<Option<RunningSession>>,
}

#[cfg(feature = "captions")]
struct RunningSession {
    capture: audio::Capture,
    stop: std::sync::Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
    device: String,
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

    pub fn status(&self, settings: &crate::config::Settings) -> CaptionsStatus {
        let model = settings.captions.model.clone();
        CaptionsStatus {
            available: self.available(),
            running: self.is_running(),
            device: self.device(),
            model_ready: model::is_downloaded(&model),
            model,
        }
    }

    #[cfg(feature = "captions")]
    fn device(&self) -> Option<String> {
        self.session
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|s| s.device.clone()))
    }

    #[cfg(not(feature = "captions"))]
    fn device(&self) -> Option<String> {
        None
    }
}

#[cfg(feature = "captions")]
impl CaptionsManager {
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
        let mut transcriber = transcribe::Transcriber::load(&model_path)?;

        let buffer = audio::SampleBuffer::default();
        let capture = audio::start(&cfg.device, buffer.clone())?;
        let device = capture.device_name.clone();

        let stop = std::sync::Arc::new(AtomicBool::new(false));
        let stop_worker = stop.clone();
        let app_worker = app.clone();
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
                        match transcriber.transcribe(&samples, &cfg.language, cfg.whisper_translate)
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

                    // Optional AI translation for non-English targets.
                    let (display, translated) = if cfg.ai_translate {
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
            device: device.clone(),
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
        crate::ai::run_completion(&profile, &system, &text).await
    })
}
