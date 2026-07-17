# Review Fixes — OCR / Image-Text Extraction

Two independent code reviews were performed on the OCR implementation. This document records
how each finding was addressed.

## Findings

### 1. OCR error hint prepended to every `run_completion` error

- **Files:** `src-tauri/src/lib.rs`
- **Finding:** `extract_image_text_inner` prepended the vision-model hint to every
  `run_completion` error, including timeouts and connection failures. A down endpoint surfaced
  as a model-capability problem.
- **Fix:** Only prepend the hint when the error message starts with `API 4` (HTTP 4xx). Timeouts,
  connection failures, parse errors, and empty outputs pass through unchanged.
- **Status:** Fixed.

### 2. Number-key shortcuts (1–9) run actions on an image selection

- **Files:** `src/Menu.tsx`
- **Finding:** The digit branch checked `!empty` but not `!isImageSelection(selection)`, so
  pressing a number key on an image selection round-tripped to the backend and returned the
  "This is an image — use Extract Text first" error.
- **Fix:** Added `!isImageSelection(selection)` to the digit guard, matching the Enter handler
  and the disabled action buttons.
- **Status:** Fixed.

### 3. OCR resize used fast box/nearest approximation instead of Lanczos3

- **Files:** `src-tauri/src/image_util.rs`, `src-tauri/src/lib.rs`
- **Finding:** `resize_to_max_dimension` used `img.thumbnail(max, max)`, which can alias text
  in downscaled screenshots.
- **Fix:** Split into two functions:
  - `resize_to_max_dimension` now uses `img.resize(max, max, FilterType::Lanczos3)` for OCR.
  - New `thumbnail_to_max_dimension` uses the fast `thumbnail` filter for the 512 px frontend preview.
  - `get_selection` now calls `thumbnail_to_max_dimension` for the preview.
- **Status:** Fixed.

### 4. No way to copy the raw extracted text directly

- **Files:** `src/Menu.tsx`, `src/api.ts`, `src/icons.tsx`, `src-tauri/src/lib.rs`, `src/styles.css`
- **Finding:** After extraction, the preview is truncated to 140 chars; the only way to get the
  full text was to run an action.
- **Fix:** Added a backend `copy_text` command that writes the full text to the clipboard via
  the PAL. Added a `copy` icon and a "Copy text" button on the post-extraction text preview.
- **Status:** Fixed.

### 5. Wayland `read_image` requests only `image/png`, silently drops JPEG offers

- **Files:** `src-tauri/src/pal/clipboard.rs`
- **Finding:** A JPEG-only clipboard offer (common from browsers) read as empty and the menu
  silently showed "no image".
- **Fix:** Kept v1 PNG-only behavior, but added a `tracing::warn!` when the clipboard contains
  `image/jpeg` but no `image/png` offer, so the user gets a clear hint in the logs. A full
  JPEG/WebP conversion pipeline would require widening the `image` crate features and is out of
  scope for this review pass.
- **Status:** Fixed (hint added). The interactive Wayland POC spike remains the highest-priority
  follow-up.

### 6. OCR error hint (duplicate of finding 1)

- **Files:** `src-tauri/src/lib.rs`
- **Fix:** Same as finding 1.
- **Status:** Fixed.

### 7. `ClipboardImage` derives `Debug` despite ADR-010 invariant

- **Files:** `src-tauri/src/pal/mod.rs`
- **Finding:** `#[derive(Debug, Clone)]` allowed a stray `tracing::error!("{:?}", img)` to dump
  megabytes of base64 to logs.
- **Fix:** Removed `Debug` from the derive: `#[derive(Clone)]`. Updated the doc comment to
  mention both the no-`Serialize` and no-`Debug` invariants.
- **Status:** Fixed.

### 8. `get_selection` holds PAL mutex during image decode/resize/base64

- **Files:** `src-tauri/src/lib.rs`
- **Finding:** The PAL lock was held while decoding, resizing, and base64-encoding a large image,
  blocking other PAL access for tens of milliseconds.
- **Fix:** Restructured `get_selection` to hold the PAL lock only for `read_text` and
  `read_image`. The image bytes are cloned out, the lock is dropped, and then
  `png_dimensions`/`thumbnail_to_max_dimension`/`to_data_uri` run outside the lock.
- **Status:** Fixed.

### 9. Number-key shortcuts (duplicate of finding 2)

- **Files:** `src/Menu.tsx`
- **Fix:** Same as finding 2.
- **Status:** Fixed.

### 10. Extracted text may not be user-selectable

- **Files:** `src/styles.css`
- **Finding:** `.selection` had no explicit `user-select` rule, and other parts of the menu use
  `user-select: none`, so the user might not be able to highlight/copy the extracted text manually.
- **Fix:** Added `user-select: text` to `.selection` and kept `user-select: none` on the empty
  state. Action buttons and labels remain `user-select: none` by default.
- **Status:** Fixed.

### 11. `resize_to_max_dimension` re-encodes when no resize is needed

- **Files:** `src-tauri/src/image_util.rs`
- **Finding:** The function re-encoded PNG even when the image was already within bounds.
- **Fix:** When both dimensions are already within `max`, the original input bytes are returned
  unchanged.
- **Status:** Fixed.

### 12. `OcrSettings.max_dimension` is not validated

- **Files:** `src-tauri/src/image_util.rs`
- **Finding:** A manually-edited `settings.json` with `maxDimension: 0` could cause
  `thumbnail(0, 0)` failures.
- **Fix:** Added `let max = max.max(1);` at the top of both resize functions to guard against
  a zero or nonsensical max dimension. The Settings UI slider already constrains the value in
  practice.
- **Status:** Fixed.

## Conflicts between reviewers

- **OCR hint status gating:** opus suggested 4xx only; opencode-go suggested 4xx/5xx. The plan
  scoped the hint to 400/422 responses. I implemented 4xx only (`e.starts_with("API 4")`) because
  5xx is a server-side error and should not steer the user toward changing models.

## Verification

- `cd src-tauri && cargo check` — clean
- `cd src-tauri && cargo test` — 22 passed
- `cd src-tauri && cargo check --features captions` — clean
- `npm run build` — passed
- `npm run tauri build` — release binary and deb/rpm bundles built; AppImage bundler failed
  because `linuxdeploy` is unavailable in this environment (same as the original implementation
  report)

## Files touched

- `src-tauri/src/lib.rs`
- `src-tauri/src/pal/mod.rs`
- `src-tauri/src/pal/clipboard.rs`
- `src-tauri/src/image_util.rs`
- `src/api.ts`
- `src/Menu.tsx`
- `src/icons.tsx`
- `src/styles.css`
- `.agents/add-an-ocr-image-text-extraction/TODO.md`
- `.agents/add-an-ocr-image-text-extraction/fixes.md`
