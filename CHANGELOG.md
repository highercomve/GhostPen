# Changelog

This changelog follows the repository's release tags. There is no v0.2.1 tag.

## [Unreleased]

## [0.2.19] - 2026-10-01

### Added

- Settings → Model & speech service: a context window for other apps' chat requests, or the same as the built-in models (the default). Apps can still ask for more per request, up to the model's maximum.
- The log records which action each menu request ran.

### Fixed

- Built-in models no longer answer a request with the previous one in mind. With hybrid models such as Qwen3.5, the state of the last request carried over: Casual after Translate rewrote the text in the translation's language and added a note about translating it.
- Translate no longer adds notes of its own ("Nota: …"); notes that are part of the text are translated with the rest.

### Build

- Oriel v0.7.0.

## [0.2.18] - 2026-09-30

### Changed

- Reorganized Settings into focused AI profile, built-in models, actions, speech, connections, and about sections.
- Made the active AI profile and provider choice clearer, with built-in model downloads in their own section.
- Clarified which model choices apply immediately and which settings need to be saved.
- Improved narrow-window navigation and simplified the model descriptions.

### Fixed

- Settings now show unsaved changes and explicitly discard them when closing without saving.
- Optional image text extraction settings stay collapsed until needed.

### Build

- Added `NO_VULKAN=1` to `scripts/install-local.sh` for local CUDA installs when the Vulkan shader build stalls. The default install still includes Vulkan.

## [0.2.17] - 2026-09-29

- Rebuilt the website homepage with larger text and clearer download choices.
- Made the website's download picker read a cached release manifest.
- Updated the Oriel dependency to v0.6.22.

## [0.2.16] - 2026-09-29

- Sped up the built-in model runner with Oriel v0.6.21 and its updated llama.cpp.

## [0.2.15] - 2026-09-29

- Made the model service answer POST requests without a body promptly.
- Removed the model-service discovery file when Windows logs off.
- Updated the Oriel dependency to v0.6.20.

## [0.2.14] - 2026-09-28

- Added a local model service so other applications can use GhostPen's built-in models.
- Added JSON-schema responses, embeddings, OpenAI tool calls, per-request context sizes, KV cache types, and flash attention to the model runner.
- Loaded service models only when needed and allowed them to be unloaded on request.
- Updated the Oriel dependency to v0.6.19.

## [0.2.13] - 2026-09-28

- Updated to Oriel v0.6.18 so the process keeps its GhostPen name on Wayland.

## [0.2.12] - 2026-09-28

- Updated to Oriel v0.6.17 so GhostPen can run on Linux systems without gtk4-layer-shell.
- Documented Linux's minimum GTK and WebKitGTK versions.

## [0.2.11] - 2026-09-28

- Unloaded a built-in model immediately when switching to an external endpoint.
- Made Whisper fall back to the CPU when GPU memory is full.
- Added `scripts/install-local.sh` to build and install a CUDA AppImage, with a CUDA library cache per Oriel version.
- Updated the Oriel dependency to v0.6.16.

## [0.2.10] - 2026-09-28

- Created secondary windows only when opened and split their frontend pages into separate bundles.
- Moved Whisper into a helper process started on first use.
- Generated TypeScript command bindings from Zig declarations and warmed up Metal after an update.
- Updated the Oriel dependency to v0.6.14.

## [0.2.9] - 2026-09-27

- Displayed readable audio-device names instead of Windows endpoint IDs.
- Added voice activity detection so Whisper processes speech rather than silence.
- Made recent captions roll into a multiline paragraph.
- Made captions and dictation overlays draggable and kept their positions when shown again.
- Updated the Oriel dependency to v0.6.13.

## [0.2.8] - 2026-09-27

- Added a choice to show action results instead of pasting them, including a Shift shortcut.
- Added paste-at-cursor after dictation, with an option to copy only.
- Added speech-model download, pause/resume, selection, and deletion in Settings, including models already installed by GhostReel.
- Added larger Whisper models and CPU fallback when a GPU buffer cannot be allocated.
- Fixed memory-safety and lifecycle issues in updates, transcription, built-in models, and image projectors.
- Updated the Oriel dependency to v0.6.11.

## [0.2.7] - 2026-09-26

- Let built-in vision models extract text from images using their image projectors.
- Stopped treating binary clipboard data offered as text as a text selection.
- Updated the Oriel dependency to v0.6.10.

## [0.2.6] - 2026-09-26

- Enabled Vulkan GPU acceleration for the Windows release.
- Signed macOS builds with GhostPen's certificate so app permissions survive updates.
- Added an MIT license, WinGet package metadata, and a workflow to submit Windows releases.
- Cached the CUDA library in CI when its build inputs are unchanged.
- Updated the Oriel dependency to v0.6.7.

## [0.2.5] - 2026-09-26

- Added Linux CUDA packages for NVIDIA GPUs, with Vulkan as a fallback.
- Updated the download guide to explain GPU support for each Linux package.

## [0.2.4] - 2026-09-26

- Enabled Vulkan GPU acceleration for Whisper and built-in models in Linux releases.

## [0.2.3] - 2026-09-26

- Added an OpenAI-compatible speech-to-text server for other local tools.
- Added version information, update checks, and signed automatic in-app updates to Settings.

## [0.2.2] - 2026-09-26

- Renamed the executable to `ghostpen` and made the packages replace the earlier Tauri package.
- Made release builds portable with Oriel v0.6.2.
- Documented how to open the unnotarized macOS app.

## [0.2.0] - 2026-09-26

- Introduced the GhostPen port to Oriel, including migration of settings from the Tauri app.
- Added the action menu, global shortcuts, tray, AI text actions, streaming Playground, image text extraction, and clipboard restoration.
- Added live captions and dictation using local Whisper models, plus audio and end-to-end tests.
- Added built-in GGUF models with CPU fallback and the `ghostpen-cli` command-line tool.
- Added Linux layer-shell overlays, platform permissions, the website, and release packages on Oriel v0.6.0.

[0.2.18]: https://github.com/highercomve/GhostPen/compare/v0.2.17...v0.2.18
[0.2.17]: https://github.com/highercomve/GhostPen/compare/v0.2.16...v0.2.17
[0.2.16]: https://github.com/highercomve/GhostPen/compare/v0.2.15...v0.2.16
[0.2.15]: https://github.com/highercomve/GhostPen/compare/v0.2.14...v0.2.15
[0.2.14]: https://github.com/highercomve/GhostPen/compare/v0.2.13...v0.2.14
[0.2.13]: https://github.com/highercomve/GhostPen/compare/v0.2.12...v0.2.13
[0.2.12]: https://github.com/highercomve/GhostPen/compare/v0.2.11...v0.2.12
[0.2.11]: https://github.com/highercomve/GhostPen/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/highercomve/GhostPen/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/highercomve/GhostPen/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/highercomve/GhostPen/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/highercomve/GhostPen/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/highercomve/GhostPen/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/highercomve/GhostPen/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/highercomve/GhostPen/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/highercomve/GhostPen/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/highercomve/GhostPen/compare/v0.2.0...v0.2.2
[0.2.0]: https://github.com/highercomve/GhostPen/releases/tag/v0.2.0
