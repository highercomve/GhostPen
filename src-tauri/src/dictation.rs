//! Voice dictation (ADR-009).
//!
//! Pipeline: **microphone capture (cpal)** → **on-device transcription (whisper.cpp)**, live in
//! the dictation overlay, → on finish an optional **AI proofread** (the active OpenAI-compatible
//! profile, built-in `proofread` prompt) → the result is **pasted in place** through the same
//! clipboard contract as the menu flow (snapshot → write → hide → paste → restore; manual-copy
//! mode where synthetic input is unavailable).
//!
//! Reuses the `captions` Cargo feature and its audio/transcribe/model stack; when compiled
//! without it the commands still exist and `start` reports the build lacks support — the app
//! degrades, it never crashes (Critical rule 3).
//!
//! Unlike captions (drain per chunk → subtitle lines), dictation **accumulates** the utterance
//! and re-transcribes the whole buffer on a cadence, so whisper refines earlier words as
//! context grows — the live text behaves like Apple dictation. Two worker threads per session:
//! a ~10 Hz RMS level meter for the waveform and the transcription loop.

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};

/// Payload for the `ghostpen://dictation` event consumed by the overlay UI.
#[derive(Clone, Serialize)]
pub struct DictationUpdate {
    /// Live partial transcript, the final text, or an error message (state `error`).
    pub text: String,
    /// `listening` | `transcribing` | `proofreading` | `done` | `cancelled` | `error`.
    pub state: String,
}

/// Snapshot of the dictation subsystem for the UI (only what the overlay reads).
#[derive(Clone, Serialize)]
pub struct DictationStatus {
    /// Whether the configured whisper model is downloaded.
    pub model_ready: bool,
    pub model: String,
    /// Whether the final transcript is AI-proofread before pasting.
    pub proofread: bool,
    /// Spoken language (`auto` or an ISO code) — mirrors `settings.dictation.language`.
    pub language: String,
}

/// Owns the running mic capture + workers. Stored in `AppState`.
#[derive(Default)]
pub struct DictationManager {
    running: AtomicBool,
    /// Abort handle for the most recent session, live or finalizing. Setting it silences
    /// that session's worker completely — no more events, no proofread delivery, no
    /// clipboard write — so Esc during "Polishing…" (or starting a new dictation) discards
    /// the old one instead of letting two sessions fight over the overlay and clipboard.
    #[cfg(feature = "captions")]
    abort: std::sync::Mutex<Option<std::sync::Arc<AtomicBool>>>,
    /// Live spoken-language code (`auto`, `en`, …) the transcription worker reads on every
    /// pass, so the overlay's language chip takes effect mid-session without restarting
    /// capture. Seeded from `settings.dictation.language` at `start`; updated by
    /// `set_language` (the `dictation_set_language` command also persists it).
    language: std::sync::Arc<std::sync::Mutex<String>>,
    /// Live "AI proofread before pasting" flag. Read at the proofread decision point inside
    /// `finalize_session`, so the overlay's switch can flip the behaviour even between the
    /// user clicking Finish and the AI call starting (useful when you realise mid-finalize
    /// that you'd rather have the raw transcript). Seeded from `settings.dictation.proofread`
    /// at `start`; updated by `set_proofread` (the `dictation_set_proofread` command also
    /// persists it).
    proofread: std::sync::Arc<AtomicBool>,
    #[cfg(feature = "captions")]
    session: std::sync::Mutex<Option<Session>>,
}

#[cfg(feature = "captions")]
struct Session {
    capture: crate::captions::audio::Capture,
    /// Tells both workers to wind down.
    stop: std::sync::Arc<AtomicBool>,
    /// true → the transcription worker finalizes (transcribe → proofread → paste) on exit;
    /// false → the session was cancelled and everything is discarded.
    finalize: std::sync::Arc<AtomicBool>,
}

impl DictationManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// Flip the spoken language live; the worker reads it on its next transcription pass.
    /// Persisting the choice to settings is the caller's responsibility.
    pub fn set_language(&self, language: &str) {
        if let Ok(mut l) = self.language.lock() {
            *l = language.to_string();
        }
    }

    /// Flip the "AI proofread before pasting" flag live; the worker reads it at the
    /// proofread decision point in `finalize_session`. Persisting to settings is the
    /// caller's responsibility (see `dictation_set_proofread`).
    pub fn set_proofread(&self, enabled: bool) {
        self.proofread.store(enabled, Ordering::SeqCst);
    }

    pub fn status(&self, settings: &crate::config::Settings) -> DictationStatus {
        // Dictation shares the captions whisper model — downloaded once, used by both.
        let model = settings.captions.model.clone();
        DictationStatus {
            model_ready: crate::captions::model::is_downloaded(&model),
            model,
            proofread: settings.dictation.proofread,
            language: settings.dictation.language.clone(),
        }
    }
}

#[cfg(feature = "captions")]
impl DictationManager {
    /// Start listening on the microphone. Returns the capture device name on success.
    pub fn start(
        &self,
        app: &tauri::AppHandle,
        settings: &crate::config::Settings,
    ) -> Result<String, String> {
        use crate::captions::{audio, model, transcribe};

        if self.is_running() {
            return Err("Dictation is already running".into());
        }
        // Starting anew silences any previous session still finalizing — the user moved on.
        let aborted = std::sync::Arc::new(AtomicBool::new(false));
        if let Ok(mut g) = self.abort.lock() {
            if let Some(old) = g.replace(aborted.clone()) {
                old.store(true, Ordering::SeqCst);
            }
        }
        let cfg = settings.dictation.clone();

        // Same whisper model as captions (downloaded once, managed in Settings → Captions).
        let model = settings.captions.model.clone();
        let model_path = model::model_path(&model)?;
        if !model_path.exists() {
            return Err(format!(
                "Whisper model \"{model}\" isn't downloaded yet. Download it in Settings → Captions.",
            ));
        }
        let mut transcriber = transcribe::Transcriber::load(&model_path)?;

        let buffer = audio::SampleBuffer::default();
        let capture = audio::start_input(&cfg.device, buffer.clone())?;
        let device = capture.device_name.clone();

        let stop = std::sync::Arc::new(AtomicBool::new(false));
        let finalize = std::sync::Arc::new(AtomicBool::new(true));
        // Seed the live language from settings; the overlay's chip can change it mid-session.
        if let Ok(mut l) = self.language.lock() {
            *l = cfg.language.clone();
        }
        let language = self.language.clone();
        // Seed the live proofread flag; the worker clones it below and the overlay's switch can
        // flip it up to the proofread decision point in `finalize_session`.
        self.proofread.store(cfg.proofread, Ordering::SeqCst);

        // Level meter: ~10 Hz RMS of the newest ~100 ms, for the overlay waveform. Kept on its
        // own thread so a slow transcription pass never freezes the animation.
        {
            let stop = stop.clone();
            let buffer = buffer.clone();
            let app = app.clone();
            let _ = std::thread::Builder::new()
                .name("ghostpen-dictation-level".into())
                .spawn(move || {
                    use tauri::Emitter;
                    while !stop.load(Ordering::SeqCst) {
                        std::thread::sleep(std::time::Duration::from_millis(100));
                        let tail = buffer.tail(audio::TARGET_RATE as usize / 10);
                        let _ = app.emit("ghostpen://dictation-level", rms_level(&tail));
                    }
                });
        }

        // Transcription worker: re-transcribe the accumulated utterance every ~1.5 s while
        // listening; on stop, finalize (final pass → optional proofread → paste) unless
        // cancelled. Detached on stop so the UI never blocks on whisper or the AI call.
        {
            let stop = stop.clone();
            let finalize = finalize.clone();
            let buffer = buffer.clone();
            let app = app.clone();
            let aborted = aborted.clone();
            let proofread = self.proofread.clone();
            let worker = move || {
                tracing::info!("dictation worker started (cumulative re-transcribe)");
                let mut last_len = 0usize;
                while !stop.load(Ordering::SeqCst) {
                    std::thread::sleep(std::time::Duration::from_millis(250));
                    let len = buffer.len();
                    // Only re-run whisper when ≥1 s total and ~1 s of new audio arrived.
                    if len < audio::TARGET_RATE as usize || len < last_len + audio::TARGET_RATE as usize {
                        continue;
                    }
                    last_len = len;
                    let samples = buffer.snapshot();
                    let lang = read_language(&language);
                    match transcriber.transcribe(&samples, &lang, false) {
                        Ok(t) => {
                            let t = clean_transcript(&t);
                            // A cancel can land while a pass is in flight — stay silent then.
                            if !t.is_empty() && !aborted.load(Ordering::SeqCst) {
                                emit_update(&app, &t, "listening");
                            }
                        }
                        Err(e) => {
                            tracing::warn!("dictation transcription error: {e}");
                        }
                    }
                }

                if aborted.load(Ordering::SeqCst) {
                    tracing::info!("dictation session aborted");
                } else if finalize.load(Ordering::SeqCst) {
                    let lang = read_language(&language);
                    let do_proofread = proofread.load(Ordering::SeqCst);
                    finalize_session(&app, transcriber, &buffer, &lang, do_proofread, &aborted);
                } else {
                    emit_update(&app, "", "cancelled");
                    tracing::info!("dictation cancelled");
                }
            };
            std::thread::Builder::new()
                .name("ghostpen-dictation".into())
                .spawn(worker)
                .map_err(|e| format!("failed to spawn dictation worker: {e}"))?;
        }

        *self.session.lock().map_err(|_| "dictation state poisoned")? = Some(Session {
            capture,
            stop,
            finalize,
        });
        self.running.store(true, Ordering::SeqCst);
        tracing::info!("dictation started on device {device}");
        Ok(device)
    }

    /// Stop listening and finalize: final transcription → optional AI proofread → paste.
    /// Returns immediately; the detached worker emits `transcribing`/`proofreading`/`done`.
    pub fn stop(&self) {
        self.end_session(true);
    }

    /// Stop and discard everything: a live session's workers wind down, and a session that
    /// already finished listening but is still transcribing/proofreading is silenced via the
    /// abort flag (Esc during "Polishing…" must NOT later paste/copy the discarded text).
    pub fn cancel(&self) {
        if let Ok(g) = self.abort.lock() {
            if let Some(a) = g.as_ref() {
                a.store(true, Ordering::SeqCst);
            }
        }
        self.end_session(false);
    }

    fn end_session(&self, finalize: bool) {
        self.running.store(false, Ordering::SeqCst);
        let session = self.session.lock().ok().and_then(|mut g| g.take());
        if let Some(mut s) = session {
            s.finalize.store(finalize, Ordering::SeqCst);
            s.stop.store(true, Ordering::SeqCst);
            // Stop the mic stream now; the detached worker finishes (or discards) on its own.
            s.capture.stop();
        }
    }
}

#[cfg(not(feature = "captions"))]
impl DictationManager {
    pub fn start(
        &self,
        _app: &tauri::AppHandle,
        _settings: &crate::config::Settings,
    ) -> Result<String, String> {
        Err("This build was compiled without captions support. Rebuild with `--features captions`."
            .into())
    }

    pub fn stop(&self) {}

    pub fn cancel(&self) {}
}

// ---- helpers (feature-gated) -----------------------------------------------------------

/// Normalized 0–1 “loudness” for the waveform from raw f32 samples. Speech RMS is typically
/// 0.02–0.3, so scale ×6 and clamp; the overlay smooths the rest.
#[cfg(feature = "captions")]
fn rms_level(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f32 = samples.iter().map(|s| s * s).sum();
    let rms = (sum / samples.len() as f32).sqrt();
    // Perceptual curve, not linear: speech RMS sits around 0.03–0.1, so `rms * k` barely lifts
    // the bars. sqrt expands the quiet range and the gain saturates on loud peaks. Tune GAIN
    // if the waveform reads too sleepy or too jumpy on your mic.
    // ponytail: fixed gain; expose in settings only if different mics need very different scaling.
    const GAIN: f32 = 2.2;
    (rms.sqrt() * GAIN).clamp(0.0, 1.0)
}

#[cfg(feature = "captions")]
fn emit_update(app: &tauri::AppHandle, text: &str, state: &str) {
    use tauri::Emitter;
    let _ = app.emit(
        "ghostpen://dictation",
        DictationUpdate {
            text: text.to_string(),
            state: state.to_string(),
        },
    );
}

/// Strip whisper's bracketed sound-event annotations ("[KNOCKING ON DOOR]", "[BLANK_AUDIO]",
/// "[MUSIC]") and collapse the leftover whitespace — dictation wants words, not noise tags.
#[cfg(feature = "captions")]
fn clean_transcript(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0usize;
    for c in text.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Read the live language, defaulting to `auto` if the lock is poisoned or the value empty.
#[cfg(feature = "captions")]
fn read_language(language: &std::sync::Arc<std::sync::Mutex<String>>) -> String {
    language
        .lock()
        .map(|l| l.clone())
        .ok()
        .filter(|l| !l.trim().is_empty())
        .unwrap_or_else(|| "auto".into())
}

/// Final pass: transcribe the full utterance, optionally proofread it via the active AI
/// profile, then deliver through the clipboard contract. Runs on the detached worker.
///
/// `aborted` is checked at every stage boundary: once set (Esc during finalization, or a new
/// session started), this worker goes silent — no events, no clipboard write. The whisper
/// context is dropped as soon as the final pass is done, BEFORE the (slow) AI call, so a new
/// dictation can load its own context without two of them stacking up in GPU memory.
#[cfg(feature = "captions")]
fn finalize_session(
    app: &tauri::AppHandle,
    mut transcriber: crate::captions::transcribe::Transcriber,
    buffer: &crate::captions::audio::SampleBuffer,
    language: &str,
    proofread: bool,
    aborted: &AtomicBool,
) {
    use crate::captions::audio;

    let samples = buffer.snapshot();
    if samples.len() < audio::TARGET_RATE as usize / 2 {
        emit_update(app, "Didn’t catch anything — try again.", "error");
        return;
    }

    emit_update(app, "", "transcribing");
    let transcript = match transcriber.transcribe(&samples, language, false) {
        Ok(t) => clean_transcript(&t),
        Err(e) => {
            if !aborted.load(Ordering::SeqCst) {
                emit_update(app, &format!("Transcription failed: {e}"), "error");
            }
            return;
        }
    };
    // Whisper is done for this session — release it now (it may hold GPU memory).
    drop(transcriber);
    if aborted.load(Ordering::SeqCst) {
        tracing::info!("dictation finalization aborted after final pass");
        return;
    }
    if transcript.is_empty() {
        emit_update(app, "Didn’t catch anything — try again.", "error");
        return;
    }
    emit_update(app, &transcript, "transcribing");

    // Optional AI proofread (the built-in strict prompt — fixes errors, never rewrites).
    let final_text = if proofread {
        emit_update(app, &transcript, "proofreading");
        match proofread_text(app, &transcript) {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!("dictation proofread failed, using raw transcript: {e}");
                transcript.clone()
            }
        }
    } else {
        transcript.clone()
    };
    if aborted.load(Ordering::SeqCst) {
        tracing::info!("dictation finalization aborted; discarding result");
        return;
    }

    deliver(app, &final_text);
}

/// Run the transcript through the active profile with the built-in `proofread` prompt
/// (blocking on Tauri's runtime — we're on a dedicated worker thread).
#[cfg(feature = "captions")]
fn proofread_text(app: &tauri::AppHandle, text: &str) -> Result<String, String> {
    let settings = crate::load_settings(app);
    let profile = settings.active().ok_or("No active AI profile")?.clone();
    let system = crate::ai::system_prompt("proofread", None, None)?;
    let text = text.to_string();
    tauri::async_runtime::block_on(async move {
        crate::ai::run_completion(&profile, &system, &text).await
    })
}

#[cfg(all(test, feature = "captions"))]
mod tests {
    use super::*;

    #[test]
    fn clean_transcript_strips_sound_tags() {
        assert_eq!(clean_transcript("[KNOCKING ON DOOR]"), "");
        assert_eq!(clean_transcript("[BLANK_AUDIO]"), "");
        assert_eq!(clean_transcript("hello [MUSIC] world"), "hello world");
        assert_eq!(clean_transcript("  plain words  "), "plain words");
    }
}

/// Deliver the final text: COPY it to the clipboard and SHOW it in the overlay — the user
/// reviews the proofread result and pastes it themselves (Ctrl+V). Dictation deliberately
/// never auto-pastes or restores the previous clipboard: unlike the menu flow there is no
/// "in place" selection to return to, the user wants to *see* what was heard before it lands,
/// and on Wayland a synthetic paste fails silently — auto-paste + restore would wipe the
/// result from both the screen and the clipboard. Shares the `busy` guard with the menu flow
/// so the clipboard write can't interleave with a menu action.
#[cfg(feature = "captions")]
fn deliver(app: &tauri::AppHandle, text: &str) {
    use tauri::Manager;

    if let Err(e) = crate::try_acquire_busy(app) {
        emit_update(app, &e, "error");
        return;
    }

    let state = app.state::<crate::AppState>();
    let write = {
        let mut pal = crate::lock_recover(&state.pal);
        pal.clipboard.write_text(text)
    };
    crate::release_busy(app);

    match write {
        Ok(()) => emit_update(app, text, "done"),
        Err(e) => emit_update(app, &format!("Clipboard error: {e}"), "error"),
    }
}
