//! Whisper model resolution + on-demand download (ADR-008).
//!
//! Models are the ggml files whisper.cpp consumes, stored under the app data dir in `models/`.
//! `ggml-base.bin` is ~140 MB; `*.en` variants are English-only and a bit faster/smaller.

use std::path::PathBuf;

/// Where GhostPen stores whisper models: `<data_dir>/GhostPen/models/`.
pub fn models_dir() -> Result<PathBuf, String> {
    let base = dirs::data_dir().ok_or("Could not resolve the OS data directory")?;
    Ok(base.join("GhostPen").join("models"))
}

/// Map a model id (`base`, `small.en`, …) to its on-disk path.
pub fn model_path(model: &str) -> Result<PathBuf, String> {
    let file = format!("ggml-{}.bin", sanitize(model));
    Ok(models_dir()?.join(file))
}

/// Only allow the limited charset that appears in whisper.cpp model ids, so a settings value
/// can never escape the models dir.
fn sanitize(model: &str) -> String {
    model
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect()
}

pub fn is_downloaded(model: &str) -> bool {
    model_path(model).map(|p| p.exists()).unwrap_or(false)
}

/// Hugging Face URL for a whisper.cpp ggml model.
fn download_url(model: &str) -> String {
    format!(
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin",
        sanitize(model)
    )
}

/// Download the model if it isn't already present. Streams to a temp file, then renames into
/// place so a partial download never looks complete. Bounded by a generous timeout.
pub async fn ensure_model(model: &str) -> Result<PathBuf, String> {
    let path = model_path(model)?;
    if path.exists() {
        return Ok(path);
    }
    let dir = models_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("Could not create models dir: {e}"))?;

    let url = download_url(model);
    tracing::info!("captions: downloading whisper model {model} from {url}");

    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(600))
        .build()
        .map_err(|e| format!("HTTP client error: {e}"))?;

    let resp = client.get(&url).send().await.map_err(|e| {
        if e.is_timeout() {
            "Model download timed out".to_string()
        } else {
            format!("Model download failed: {e}")
        }
    })?;
    if !resp.status().is_success() {
        return Err(format!(
            "Model download returned {} — is \"{model}\" a valid whisper model id?",
            resp.status()
        ));
    }

    let tmp = path.with_extension("bin.part");
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("Model download read error: {e}"))?;
    std::fs::write(&tmp, &bytes).map_err(|e| format!("Could not write model file: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Could not finalize model file: {e}"))?;
    tracing::info!("captions: model {model} ready ({} bytes)", bytes.len());
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_path_traversal() {
        assert_eq!(sanitize("../../etc/passwd"), "....etcpasswd");
        assert_eq!(sanitize("base.en"), "base.en");
        assert_eq!(sanitize("small-q5_1"), "small-q5_1");
    }

    #[test]
    fn model_path_lands_in_models_dir() {
        if let Ok(p) = model_path("base") {
            assert!(p.ends_with("models/ggml-base.bin"));
        }
    }
}
