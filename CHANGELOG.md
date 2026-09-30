# Changelog

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

[0.2.18]: https://github.com/highercomve/GhostPen/compare/v0.2.17...v0.2.18
