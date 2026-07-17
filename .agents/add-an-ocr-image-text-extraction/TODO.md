# TODO — OCR / image-text extraction

## Completed
- [x] Plan reviewed by architect; blocking fixes merged into `architecture.md` (2026-07-17)
- [x] ADR-010 / ADR-011 appended to `.agents/architecture.md`
- [x] Steps 1–3: PAL image trait + both backends + image_util (`image`/`base64` deps)
- [x] Steps 4–5: `ClipboardSnapshot`/`SelectionContent` state; trigger snapshots images, resets `current_input`
- [x] Steps 6–7: `UserContent` in ai.rs (run_completion only) + `extract_image_text` command with model override
- [x] Step 8: `process_inner` reads `current_input` with clipboard fallback; image-kind restore
- [x] Step 9: `OcrSettings` (empty prompt/model = defaults)
- [x] Steps 10–12: `SelectionInfo` DTO + api.ts, Menu.tsx image flow, Settings OCR card with privacy note
- [x] Step 14: unit tests (image_util, DTO shape, UserContent serialization)
- [x] `cargo check`, `cargo test`, `npm run build`, `npm run tauri build` (binary built; AppImage bundler env issue only)

## Completed in review-fix pass
- [x] Gate OCR vision-capability hint on HTTP 4xx only; pass timeouts/connect errors through unchanged
- [x] Guard 1–9 number-key shortcuts against image selections
- [x] Use Lanczos3 for OCR resize; keep fast thumbnail filter for the 512 px preview
- [x] Add "Copy text" button for post-extraction text selections
- [x] Surface Wayland JPEG-only-offer hint via `tracing::warn!` (v1 remains PNG-only)
- [x] Remove `Debug` derive from `ClipboardImage` per ADR-010
- [x] Drop PAL lock before image decode/resize/base64 in `get_selection`
- [x] Make `.selection` text user-selectable
- [x] Skip re-encode when no resize is required; clamp `max` to ≥1

## Pending / follow-up
- [ ] POC spike: manual Wayland `read_image`/`write_image` smoke test on Hyprland (highest-risk unknown; environment currently not set up for an interactive end-to-end clipboard round-trip)
- [ ] Manual checklist (architecture.md Step 14): requires running the built binary and exercising text/image clipboard flows on the target desktop
- [ ] Cross-platform manual verification on at least one other platform (Windows/macOS)
