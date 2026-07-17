//! OpenAI-compatible AI client (plan §5/§8, ADR-006, ADR-011).
//!
//! One code path for every provider (Ollama, OpenAI, OpenRouter, Groq, LM Studio, custom):
//! only baseUrl, optional bearer key, and model id differ. Every request is timeout-bounded.
//! Text actions and image-text extraction (OCR) share the same `run_completion` path.

use crate::config::Profile;
use serde::{ser::SerializeSeq, Serialize, Serializer};
use serde_json::json;
use std::time::Duration;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(60); // cloud models can be slow

/// Hard cap on generated tokens. Menu actions edit a *selection*, so the output is bounded
/// by the input — a few thousand tokens is always plenty. Without this, a model that fails
/// to emit a stop token runs away (observed: ~6000 tokens on a one-line translate), and at a
/// local model's ~50 tok/s that blows past `TOTAL_TIMEOUT` → "Request timed out". 2048 tokens
/// finishes in ~40s even at 50 tok/s, comfortably inside the timeout.
const MAX_TOKENS: u32 = 2048;

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(TOTAL_TIMEOUT)
        .build()
        .map_err(|e| format!("HTTP client error: {e}"))
}

fn map_send_error(e: reqwest::Error) -> String {
    if e.is_timeout() {
        "Request timed out — is the endpoint reachable?".into()
    } else if e.is_connect() {
        "Could not connect to the endpoint.".into()
    } else {
        format!("Request failed: {e}")
    }
}

/// User content sent to the `/chat/completions` endpoint. Text callers produce the same
/// wire format as before (`"content": "..."`); image callers produce the two-part multimodal
/// array (`"image_url"` with a complete data URI).
#[derive(Clone, Debug)]
pub enum UserContent {
    Text(String),
    ImageWithText { text: String, data_uri: String },
}

impl UserContent {
    /// Convenience constructor for image extraction: wraps the prompt text and the data URI.
    pub fn image_with_text(text: impl Into<String>, data_uri: impl Into<String>) -> Self {
        UserContent::ImageWithText {
            text: text.into(),
            data_uri: data_uri.into(),
        }
    }
}

impl Serialize for UserContent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            UserContent::Text(s) => s.serialize(serializer),
            UserContent::ImageWithText { text, data_uri } => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                seq.serialize_element(&json!({"type": "text", "text": text}))?;
                seq.serialize_element(&json!({
                    "type": "image_url",
                    "image_url": { "url": data_uri }
                }))?;
                seq.end()
            }
        }
    }
}

/// Strict system prompts — return ONLY the transformed text, no filler.
///
/// `level` (subtle | balanced | strong) tunes intensity for the tone/length actions
/// (professional, casual, concise, expand). Proofread and translate ignore it.
pub fn system_prompt(
    action: &str,
    target_lang: Option<&str>,
    level: Option<&str>,
) -> Result<String, String> {
    let level = level.unwrap_or("balanced");
    Ok(match action {
        "proofread" => "Fix all spelling, grammar, syntax, and punctuation errors. Maintain the original tone. Return ONLY the finalized text. No conversational filler, notes, or wrapper quotes.".into(),
        "professional" => match level {
            "subtle" => "Lightly adjust the text to sound a bit more professional and polished, staying close to the original wording and length. Return ONLY the rewritten text, with no explanations.".into(),
            "strong" => "Rewrite the text into a highly formal, polished, corporate-professional tone. Return ONLY the rewritten text, with no explanations.".into(),
            _ => "Rewrite the text to be professional, polite, and clear. Return ONLY the rewritten text, with no explanations.".into(),
        },
        "casual" => match level {
            "subtle" => "Lightly relax the tone to be a bit more casual and friendly, keeping it close to the original. Return ONLY the rewritten text, with no explanations.".into(),
            "strong" => "Rewrite the text in a very casual, relaxed, informal tone — like chatting with a close friend. Return ONLY the rewritten text, with no explanations.".into(),
            _ => "Rewrite the text in a casual, friendly, conversational tone. Keep it natural and approachable. Return ONLY the rewritten text, with no explanations.".into(),
        },
        "concise" => match level {
            "subtle" => "Tighten the text slightly, trimming obvious redundancy while keeping nearly all detail. Return ONLY the condensed text.".into(),
            "strong" => "Aggressively condense the text to the absolute minimum needed to convey the essential point. Return ONLY the condensed text.".into(),
            _ => "Condense the text to be short and precise while preserving all core information. Return ONLY the condensed text.".into(),
        },
        "expand" => match level {
            "subtle" => "Expand the text slightly with a little more detail and clarity, keeping it close to the original length. Return ONLY the expanded text, with no explanations or filler.".into(),
            "strong" => "Substantially expand the text with rich detail, examples, and elaboration, significantly increasing its length while preserving meaning and tone. Return ONLY the expanded text, with no explanations or filler.".into(),
            _ => "Expand the text with more detail, elaboration, and supporting context while preserving its original meaning and tone. Return ONLY the expanded text, with no explanations or filler.".into(),
        },
        "translate" => {
            let lang = target_lang.unwrap_or("English");
            format!("Auto-detect the source language. Translate the text into natural, fluent {lang}, preserving formatting and tone. Return ONLY the translated text — no filler, explanations, or quotes.")
        }
        other => return Err(format!("Invalid action: {other}")),
    })
}

/// System prompt for a freeform, user-typed instruction (the menu's prompt bar). The
/// instruction is applied to the selected text; only the transformed result is returned.
pub fn custom_system_prompt(instruction: &str) -> String {
    format!(
        "You are a precise text editor. Apply the following instruction to the user's text: \
         \"{}\". Return ONLY the resulting text — no explanations, notes, preamble, or wrapper quotes.",
        instruction.trim().replace('"', "'")
    )
}

/// System prompt for image-text extraction. Empty `settings.ocr.system_prompt` means use this.
pub fn ocr_system_prompt() -> &'static str {
    "Extract all visible text from the image. Preserve line breaks and paragraph structure \
     as closely as possible. Return ONLY the extracted text, with no markdown, no \
     explanations, and no wrapper quotes."
}

/// Run a chat completion and return the trimmed assistant message.
///
/// `user` is either plain text (text actions) or a multimodal text+image payload (OCR).
/// The wire format for text is byte-identical to the pre-OCR version.
pub async fn run_completion(profile: &Profile, system: &str, user: &UserContent) -> Result<String, String> {
    let base = profile.base_url.trim_end_matches('/');
    let mut req = client()?.post(format!("{base}/chat/completions")).json(&json!({
        "model": profile.model,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user }
        ],
        "temperature": profile.temperature,
        "max_tokens": MAX_TOKENS,
        // These are text-editing actions — the transformed text is the whole answer, so a
        // model's "thinking" phase is pure latency (observed: a thinking gemma spent its
        // entire token budget on reasoning and returned EMPTY content → timeout). Ask the
        // backend to skip it. Both spellings are covered: `chat_template_kwargs.enable_thinking`
        // (llama.cpp/vLLM/SGLang) and `think` (Ollama). Backends that don't know a field ignore it.
        "chat_template_kwargs": { "enable_thinking": false },
        "think": false,
        "stream": false
    }));
    if !profile.api_key.is_empty() {
        req = req.bearer_auth(&profile.api_key);
    }

    let resp = req.send().await.map_err(map_send_error)?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        let snippet = truncate(&body);
        return Err(if snippet.is_empty() {
            format!("API returned {status}")
        } else {
            format!("API {status}: {snippet}")
        });
    }

    let data: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    let output = data["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    if output.is_empty() {
        return Err("Model returned empty output".into());
    }
    Ok(output)
}

fn truncate(s: &str) -> String {
    let s = s.trim();
    if s.len() > 200 {
        // Floor to a UTF-8 boundary so a non-ASCII error body doesn't panic on slicing.
        let end = s.floor_char_boundary(200);
        format!("{}\u{2026}", &s[..end])
    } else {
        s.to_string()
    }
}

/// Streaming chat completion (SSE). Calls `on_chunk` for each content delta and returns the
/// full assembled text. Lines are buffered across network chunks so multi-byte UTF-8 and
/// partial frames are handled correctly.
///
/// Stays text-only; no OCR/stream consumer exists.
pub async fn run_completion_stream<F: FnMut(&str)>(
    profile: &Profile,
    system: &str,
    user: &str,
    mut on_chunk: F,
) -> Result<String, String> {
    use futures_util::StreamExt;

    let user_content = UserContent::Text(user.to_string());
    let base = profile.base_url.trim_end_matches('/');
    let mut req = client()?.post(format!("{base}/chat/completions")).json(&json!({
        "model": profile.model,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user_content }
        ],
        "temperature": profile.temperature,
        "max_tokens": MAX_TOKENS,
        // See `run_completion`: skip the model's thinking phase — it's pure latency for a
        // text transform. `chat_template_kwargs.enable_thinking` (llama.cpp/vLLM) + `think` (Ollama).
        "chat_template_kwargs": { "enable_thinking": false },
        "think": false,
        "stream": true
    }));
    if !profile.api_key.is_empty() {
        req = req.bearer_auth(&profile.api_key);
    }

    let resp = req.send().await.map_err(map_send_error)?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("API {status}: {}", truncate(&body)));
    }

    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    let mut full = String::new();

    while let Some(item) = stream.next().await {
        let bytes = item.map_err(|e| format!("Stream error: {e}"))?;
        buf.extend_from_slice(&bytes);
        // Process each complete line in the buffer.
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line_bytes: Vec<u8> = buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line_bytes);
            let line = line.trim();
            let Some(data) = line.strip_prefix("data:") else {
                continue;
            };
            let data = data.trim();
            if data == "[DONE]" {
                return finalize(full);
            }
            if data.is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(data) {
                if let Some(delta) = v["choices"][0]["delta"]["content"].as_str() {
                    if !delta.is_empty() {
                        full.push_str(delta);
                        on_chunk(delta);
                    }
                }
            }
        }
    }
    finalize(full)
}

fn finalize(full: String) -> Result<String, String> {
    let trimmed = full.trim().to_string();
    if trimmed.is_empty() {
        Err("Model returned empty output".into())
    } else {
        Ok(trimmed)
    }
}

/// List available models via `GET /models` (OpenAI-compatible). Returns model ids.
pub async fn list_models(base_url: &str, api_key: &str) -> Result<Vec<String>, String> {
    let base = base_url.trim_end_matches('/');
    let mut req = client()?.get(format!("{base}/models"));
    if !api_key.is_empty() {
        req = req.bearer_auth(api_key);
    }
    let resp = req.send().await.map_err(map_send_error)?;
    if !resp.status().is_success() {
        return Err(format!("Models request returned {}", resp.status()));
    }
    let data: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    let mut ids: Vec<String> = data["data"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| m["id"].as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    ids.sort();
    if ids.is_empty() {
        return Err("No models returned by the endpoint".into());
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn user_content_text_serializes_to_string() {
        let content = UserContent::Text("hello".into());
        let json = serde_json::to_value(&content).unwrap();
        assert_eq!(json, json!("hello"));
    }

    #[test]
    fn user_content_image_serializes_two_parts() {
        let content = UserContent::image_with_text("Extract all text from this image.", "data:image/png;base64,abc");
        let json = serde_json::to_value(&content).unwrap();
        let arr = json.as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0], json!({"type":"text","text":"Extract all text from this image."}));
        assert_eq!(arr[1], json!({"type":"image_url","image_url":{"url":"data:image/png;base64,abc"}}));
    }

    #[test]
    fn data_uri_prefix_appears_once() {
        let content = UserContent::image_with_text("x", "data:image/png;base64,xyz");
        let json = serde_json::to_string(&content).unwrap();
        assert_eq!(json.matches("data:image/png;base64,").count(), 1);
    }
}
