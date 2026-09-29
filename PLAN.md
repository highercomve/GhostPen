# GhostPen on Oriel: port plan

A port of GhostPen (`~/Code/ghostpen-tauri`, Tauri v2 + Rust) to Oriel (Zig), built
the way any Oriel developer would: the released `oriel` CLI, `oriel init`,
`oriel dev/build/package`, and only Oriel's public API. When GhostPen needs
something Oriel lacks, the gap is fixed in Oriel itself (Milestone 10), not
worked around here.

Feature parity target: everything in the Tauri app, same settings schema
(`settings.json`, camelCase) so a user can copy their settings across.

## Map

| GhostPen (Tauri) | GhostPen on Oriel |
| --- | --- |
| Rust commands (`lib.rs`) | `Commands` in `src/main.zig` (same names, same JSON shapes) |
| Events `ghostpen://…` | `Events` (same names) via `App.emit` / `Window.emit` |
| 5 static windows (menu, settings, playground, captions, dictation) | `App.openWindow` at setup, hidden; hash routes unchanged |
| tauri-plugin-store `settings.json` | `src/settings.zig`: JSON file in the app data dir, schema + defaults |
| reqwest AI client, SSE, vision | `src/ai.zig` on `std.http.Client` (timeouts, SSE, image_url) |
| arboard / wl-clipboard-rs | `oriel.clipboard` (text + PNG images) |
| enigo copy/paste | `oriel.input.copy/paste` |
| tauri-plugin-global-shortcut (+ compositor binds on Wayland) | `oriel.global_shortcut` (GlobalShortcuts portal on Wayland: no compositor binds needed where the portal exists) |
| tray | `oriel.tray` (left click → menu flow) |
| single-instance + `--trigger` etc. | `App.Config.on_second_instance` (Oriel M10) |
| cpal + whisper-rs captions / dictation | `oriel.audio_capture` + `oriel.whisper` (+ CUDA via `-Dggml_cuda`) |
| `image` crate (resize, PNG) | `src/image.zig` (PNG decode/resize/encode) |
| ghostpen-cli | second executable `ghostpen-cli` in build.zig, sharing `ai.zig` + `settings.zig` |
| STT HTTP server (opt-in) | later: `oriel.media_server`'s HTTP stack or std.http.Server |
| React frontend (plain CSS) | copied as-is; `api.ts` rewritten over the generated `oriel.ts` |

## Oriel gaps (Milestone 10 in Oriel's PLAN.md)

1. Overlay windows: `transparent`, `always_on_top`, `skip_taskbar`, `visible` (create hidden), runtime `center`, `setPosition`, `setClickThrough`, `setAlwaysOnTop`, and the monitor work area. Wayland: layer-shell overlays (gtk4-layer-shell) where available.
2. Single instance with argument forwarding on every OS (`--trigger` from a second launch).
3. Start with no window shown (daemon apps: tray + hotkey first).
4. Windows audio capture (WASAPI, loopback for captions) — today a stub.

## Steps

1. Scaffold (done): `oriel init ghostpen-oriel --template react --id dev.ghostpen.Oriel`.
2. Oriel M10 (framework), then bump the app to that Oriel release.
3. Core: settings, AI client (+ tests against a mock server), prompts, CLI.
4. Menu flow: hotkey/tray/second-instance → snapshot → copy → menu → action → paste → restore; OCR path.
5. Playground (streaming), Settings.
6. Captions + dictation (audio, whisper model download, overlays).
7. Packaging (deb/rpm/AppImage, setup.exe, .app/.dmg), permissions (`microphone`, `system_audio`, `accessibility`), docs.

Every step: `oriel check`, unit tests, headless run, and a memory-safety review.
