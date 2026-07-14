//! Local OpenAI-compatible transcription server (optional).
//!
//! Exposes the captions whisper engine over HTTP so other local tools — e.g. an
//! agent that receives voice notes — transcribe through GhostPen's *own* whisper
//! model instead of standing up a second whisper process. One binary, one model
//! file on disk, the GPU build you already have.
//!
//! Enabled with `GHOSTPEN_STT_SERVER=1`. Binds `GHOSTPEN_STT_BIND`
//! (default `0.0.0.0:8771`) and serves `POST /v1/audio/transcriptions` in the
//! OpenAI Whisper API shape (multipart `file` field → `{ "text": ... }`, or the
//! raw transcript when `response_format=text`).
//!
//! It transcribes through the shared [`ModelPool`] — the SAME resident model the
//! live captions and dictation workers use, serialized behind one mutex. So a
//! voice note and an active dictation never load two copies into GPU memory, and
//! never run two inferences on one CUDA context at once.
//!
//! ponytail: decode shells out to `ffmpeg` (already on the host; handles
//! ogg/opus/m4a/wav/mp3). Swap to symphonia + symphonia-adapter-libopus for a
//! fully self-contained, ffmpeg-free cross-platform binary.

#![cfg(feature = "captions")]

use std::io::Write;
use std::net::SocketAddr;
use std::process::{Command, Stdio};
use std::sync::Arc;

use axum::{
    extract::{Multipart, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde_json::json;

use super::pool::ModelPool;

#[derive(Clone)]
struct ServerState {
    pool: Arc<ModelPool>,
    app: tauri::AppHandle,
    /// `GHOSTPEN_STT_MODEL` override; when `None`, the live Settings → Captions
    /// model is read per request so the server always tracks what dictation and
    /// captions use (one shared model, no thrash on a settings change).
    model_override: Option<String>,
    language: String,
}

impl ServerState {
    /// The model to serve right now: the env override, else the live captions setting.
    fn model(&self) -> String {
        self.model_override
            .clone()
            .unwrap_or_else(|| crate::load_settings(&self.app).captions.model)
    }
}

/// Start the transcription server on Tauri's runtime when `GHOSTPEN_STT_SERVER=1`.
/// Serves the model configured in Settings → Captions (read live per request) so
/// it shares one resident context with the captions/dictation workers. Override
/// with `GHOSTPEN_STT_MODEL`. Any misconfiguration logs and returns — never panics.
pub fn maybe_spawn(pool: Arc<ModelPool>, app: tauri::AppHandle) {
    if std::env::var("GHOSTPEN_STT_SERVER").ok().as_deref() != Some("1") {
        return;
    }

    let bind = std::env::var("GHOSTPEN_STT_BIND").unwrap_or_else(|_| "0.0.0.0:8771".into());
    let language = std::env::var("GHOSTPEN_STT_LANGUAGE").unwrap_or_else(|_| "auto".into());
    let model_override = std::env::var("GHOSTPEN_STT_MODEL").ok().filter(|s| !s.trim().is_empty());

    let addr: SocketAddr = match bind.parse() {
        Ok(a) => a,
        Err(e) => {
            tracing::warn!("STT server: invalid GHOSTPEN_STT_BIND {bind:?}: {e}");
            return;
        }
    };

    let state = ServerState {
        pool,
        app,
        model_override,
        language,
    };

    // Pre-warm the model so the first request isn't slow. If it can't load (not
    // downloaded), don't start — requests would only error.
    let initial_model = state.model();
    if let Err(e) = state.pool.ensure(&initial_model) {
        tracing::warn!("STT server: cannot load model {initial_model:?}: {e}; not starting");
        return;
    }

    tauri::async_runtime::spawn(async move {
        let model = initial_model;
        let router = Router::new()
            .route("/health", get(|| async { "ok" }))
            .route("/v1/audio/transcriptions", post(transcribe_handler))
            .with_state(state);

        match tokio::net::TcpListener::bind(addr).await {
            Ok(listener) => {
                tracing::info!("STT server listening on http://{addr} (model {model})");
                if let Err(e) = axum::serve(listener, router).await {
                    tracing::warn!("STT server stopped: {e}");
                }
            }
            Err(e) => tracing::warn!("STT server: cannot bind {addr}: {e}"),
        }
    });
}

async fn transcribe_handler(
    State(state): State<ServerState>,
    mut multipart: Multipart,
) -> Result<Response, (StatusCode, String)> {
    let mut audio: Option<Vec<u8>> = None;
    let mut language = state.language.clone();
    // OpenAI default is "json"; clients (incl. Hermes) may ask for "text" and then
    // expect the raw transcript as the body, not a JSON envelope.
    let mut response_format = String::from("json");

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?
    {
        match field.name() {
            Some("file") => {
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
                audio = Some(bytes.to_vec());
            }
            // OpenAI clients send `language` (ISO code); honor it over the default.
            Some("language") => {
                if let Ok(v) = field.text().await {
                    let v = v.trim();
                    if !v.is_empty() {
                        language = v.to_string();
                    }
                }
            }
            Some("response_format") => {
                if let Ok(v) = field.text().await {
                    let v = v.trim();
                    if !v.is_empty() {
                        response_format = v.to_lowercase();
                    }
                }
            }
            // Drain ignored fields (model, temperature, …) so the stream advances.
            _ => {
                let _ = field.bytes().await;
            }
        }
    }

    let audio = audio.ok_or((StatusCode::BAD_REQUEST, "missing 'file' field".into()))?;
    let samples = decode_to_pcm16k(&audio)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("audio decode failed: {e}")))?;

    // Transcription is blocking + serialized inside the pool; run it off the async pool.
    // Resolve the model per request so a Settings → Captions change is picked up live.
    let pool = state.pool.clone();
    let model = state.model();
    let text = tokio::task::spawn_blocking(move || -> Result<String, String> {
        pool.transcribe(&model, &samples, &language, false)
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // `text`/`srt`/`vtt` → raw body (OpenAI returns the transcript as-is); everything
    // else (json, verbose_json, default) → the `{ "text": ... }` envelope.
    Ok(match response_format.as_str() {
        "text" | "srt" | "vtt" => text.into_response(),
        _ => Json(json!({ "text": text })).into_response(),
    })
}

/// Decode arbitrary audio bytes (ogg/opus, m4a, wav, mp3, webm…) to 16 kHz mono
/// f32 — what whisper expects — by piping through ffmpeg.
fn decode_to_pcm16k(bytes: &[u8]) -> Result<Vec<f32>, String> {
    let mut child = Command::new("ffmpeg")
        .args([
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", "pipe:0",
            "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn ffmpeg (is it installed?): {e}"))?;

    // Feed stdin on a separate thread so a large input can't deadlock against
    // ffmpeg filling its stdout pipe.
    let mut stdin = child.stdin.take().ok_or("ffmpeg stdin unavailable")?;
    let input = bytes.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
        // drop closes stdin → ffmpeg sees EOF
    });

    let out = child
        .wait_with_output()
        .map_err(|e| format!("ffmpeg wait: {e}"))?;
    let _ = writer.join();

    if !out.status.success() {
        return Err(format!(
            "ffmpeg exited {:?}: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }

    let mut samples = Vec::with_capacity(out.stdout.len() / 4);
    for c in out.stdout.chunks_exact(4) {
        samples.push(f32::from_le_bytes([c[0], c[1], c[2], c[3]]));
    }
    Ok(samples)
}
