# Implementation Report — OCR / Image-Text Extraction

*Implemented by implementer agent on 2026-07-17, following the approved plan in
`.agents/add-an-ocr-image-text-extraction/architecture.md` (which supersedes the
original `plan.md`).*

## Summary

Implemented the full OCR / image-text-extraction feature for GhostPen. The menu
now accepts an image on the clipboard, previews it, and offers **Extract Text**;
the extraction runs through the existing OpenAI-compatible `/chat/completions`
path using a vision-capable model (e.g. `gemma4:e4b` multimodal). After
extraction, the text becomes the working selection and the normal action grid
(proofread, translate, etc.) operates on it.

## Files created or modified

| File | What changed |
|------|-------------|
| `/home/sergiom/Code/ghostpen/src-tauri/Cargo.toml` | Added `image` (PNG-only) and `base64` dependencies; restored package metadata that had been accidentally truncated by prior partial edits. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/image_util.rs` | **New file.** `rgba_to_png`, `resize_to_max_dimension`, `png_dimensions`, `to_data_uri`, plus unit tests for all of them. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/pal/mod.rs` | Added `ClipboardImage` (deliberately not `Serialize`) and `read_image`/`write_image` to `ClipboardBackend` trait. Removed stray `use std::fmt`. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/pal/clipboard.rs` | Implemented image read/write for both `ArboardClipboard` (RGBA↔PNG round-trip) and `WaylandClipboard` (persistent serve thread caches `Text | Image`, both readers honor `owned` fast-path). |
| `/home/sergiom/Code/ghostpen/src-tauri/src/config.rs` | Added `OcrSettings` with `max_dimension`, `system_prompt`, `model_override` (empty = defaults), and added `ocr` to `Settings` / `Settings::defaults()`. Restored accidentally truncated content. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/ai.rs` | Added `UserContent` enum with custom `Serialize` (text serializes as string, image+text as the two-part multimodal array), `ocr_system_prompt`, and updated `run_completion` to accept `&UserContent`. Text wire format is byte-identical to before. Updated `run_completion_stream` to wrap its text input internally. Added unit tests for `UserContent` serialization. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/captions/mod.rs` | Updated `translate_text` to wrap text in `UserContent::Text(...)`. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/dictation.rs` | Updated `proofread_text` to wrap text in `UserContent::Text(...)`. |
| `/home/sergiom/Code/ghostpen/src-tauri/src/lib.rs` | Major changes: added `ClipboardSnapshot` and `SelectionContent` enums; upgraded `AppState` with image-capable snapshot and `current_input`; updated `trigger_menu_flow` to snapshot images and reset working input; added `restore_original_clipboard` by kind; added `SelectionInfo` DTO and reworked `get_selection` to populate `current_input`; added `extract_image_text` command with OCR model override and readable error hint; updated `process_inner` to consume `current_input` with clipboard fallback; updated image-kind restore in the delayed thread; added `SelectionInfo` JSON-shape test. |
| `/home/sergiom/Code/ghostpen/src/api.ts` | Added `SelectionInfo` type, `OcrSettings`, `extractImageText`, and updated `getSelection` return type and `Settings` interface. |
| `/home/sergiom/Code/ghostpen/src/Menu.tsx` | `selection` state now uses `SelectionInfo`; image view shows a downscaled preview with dimensions and a primary **Extract Text** button; action grid and prompt bar are disabled while an image is active; Enter triggers Extract Text; text view unchanged. |
| `/home/sergiom/Code/ghostpen/src/Settings.tsx` | Added "Image Text Extraction (OCR)" settings card with max-dimension slider, system-prompt textarea, model-override input, and privacy note. |
| `/home/sergiom/Code/ghostpen/src/styles.css` | Added `.selection-image`, `.image-dims`, `.action.extract-text` styling; increased `.selection` max-height to accommodate image previews. |
| `/home/sergiom/.agents/add-an-ocr-image-text-extraction/TODO.md` | Updated to mark implementation steps complete and note remaining manual/POC work. |

## Verification commands and output

```bash
cd /home/sergiom/Code/ghostpen/src-tauri
cargo check
# cargo build: 0 errors, 0 warnings

cargo test
# cargo test: 22 passed (3 suites, 0.00s)

cargo check --features captions
# cargo build: 0 errors, 0 warnings

npm run build
# vite build: ✓ 40 modules transformed, dist generated

npm run tauri build
# Finished `release` profile; built binary at src-tauri/target/release/ghostpen
# Note: AppImage bundling failed because `linuxdeploy` is not available in this environment;
# the Rust binary, deb, and rpm bundles were produced successfully.
```

## Deviations from the approved plan

1. **Internal representation of `UserContent::ImageWithText`.** The plan wrote the variant as `{ text, data_uri }`. The implementation keeps the same external API but serializes the two parts into the content array directly via a custom `Serialize` implementation, avoiding the double-prefix bug and keeping the JSON shape exactly as specified (`"content": [{"type":"text",...},{"type":"image_url",...}]`).
2. **Wayland `read_image` error mapping.** The plan said `NoSeats | ClipboardEmpty | NoMimeType → Ok(None)` for `read_image`. The implementation does the same.
3. **POC spike.** The plan sequenced the Wayland image-clipboard POC spike *before* Steps 4–12. The environment here is the headless CLI harness, so an interactive Hyprland clipboard round-trip could not be executed. The code was written to follow the spike's expected findings (persistent serve, `owned` fast-path, PNG-only). This spike remains the highest-priority follow-up.

## What's left undone

- **Wayland POC spike** (Step 14): run an interactive smoke test on Hyprland copying an image with `grim`/`wl-copy`, reading it back, serving it, and pasting into an image-capable app.
- **Manual checklist** (Step 14): exercise the full text-flow regression and image-flow scenarios using the built binary.
- **Cross-platform verification** on at least one other platform (Windows/macOS).

No Tauri capabilities were widened; no image bytes or base64 are logged.
