# TODO — GhostPen Implementation

Ordered, dependency-aware task list derived from [`plan.md`](./plan.md) and
[`architecture.md`](./architecture.md). Work top-to-bottom; phases gate each other.
The Implementer ([`implementer.md`](./implementer.md)) checks items off here as they complete.

**Golden rules while implementing (from architecture Critical rules):** route all OS calls
through the PAL · runtime session detection, not just `cfg!` · snapshot clipboard *before*
copy · never `.unwrap()` an OS handle · bound every network call · default model
`gemma4:e4b` · never log keys/clipboard.

### Dev-environment status

**Current (2026-06-05) — real target: x86_64 Arch Linux, Wayland / Hyprland.**
- **Session:** `wayland-1`, compositor **Hyprland**. This is a real desktop target, so the
  three Phase-0 unknowns (clipboard, input synthesis, overlay) are now resolvable here.
- **Toolchain:** Rust 1.96.0 ✅ · Node 24 ✅. Tauri deps present (Arch).
- **AI backends:** local **Ollama** on `:11434` (active model `gemma4:e2b`) **and** **LM
  Studio** on `:1234` (`google/gemma-4-e2b` loaded) — both verified end-to-end.
- **Wayland reality (verified here):** `enigo` synthetic input **fails silently** on Hyprland
  (reports Ok, keystrokes don't land) → app runs in **manual-copy mode**; the Wayland
  **clipboard** needs `wl-clipboard-rs` (arboard is X11-only and loses writes over XWayland).
  Global hotkey is bound in the **compositor** (`Ctrl+Shift+A → ghostpen --trigger`).

<details><summary>Previous dev machine (2026-06-04, superseded) — aarch64 Crostini Chromebook</summary>

aarch64 Linux, Wayland (`wayland-0`), compositor = ChromeOS/Sommelier (reported `X-Generic`).
Couldn't test global hotkey / synthetic input / overlay-on-top (Crostini limits); clipboard
WAS shared with ChromeOS. Used `gemma4:31b-cloud` (Ollama Cloud) since local HW couldn't run
`gemma4:e4b`. Dev/test in manual-copy mode. Shipped default stayed `gemma4:e4b`.
</details>

---

## Phase 0 — POC spikes (validate the High risks) 🚩 — RESOLVED on real target

- [x] **0.1 Clipboard spike (ADR-002).** ✅ Resolved on Hyprland/Wayland. arboard is
      **X11-only** here and loses writes across the XWayland bridge, so the Wayland path uses
      **`wl-clipboard-rs`**: read via `get_contents`, write via a detached **persistent serve**
      thread (`foreground(true)`, `ServeRequests::Unlimited`). Self-read deadlock fixed by
      caching the served value while we own the selection (see Phase 10).
- [x] **0.2 Input-synthesis spike (§10b).** ✅ Resolved: `enigo` (libei) **fails silently** on
      native Wayland/Hyprland — it returns Ok but keystrokes never reach host windows. App
      **degrades to manual-copy mode** there (ADR-005/007). `virtual_keyboard_v1`/libei-into-
      host deferred. Works natively on X11/Windows/macOS.
- [x] **0.3 Overlay spike.** ✅ Overlay shown via Hyprland window-rules (floating, centered,
      pinned to follow the active workspace) + Tauri `alwaysOnTop`. `gtk-layer-shell` not
      needed for v1.

## Phase 1 — Scaffold & dependencies (§4)

- [x] **1.0** `./scripts/install-deps.sh` (cross-distro/macOS, shellcheck-clean).
- [x] **1.1** Scaffolded Tauri v2 + React/TS/Vite; renamed `tauri-app`→`ghostpen`.
- [x] **1.2** Plugins wired in `lib.rs`: `single-instance` (first), `store`,
      `global-shortcut`, `opener`.
- [x] **1.3** Rust crates (newer than plan): enigo 0.6.1, reqwest 0.13.4, arboard 3.6,
      **wl-clipboard-rs 0.9** (Linux), tokio, tracing(+subscriber), futures-util.
- [x] **1.4** `tauri.conf.json` windows: `main` (frameless, alwaysOnTop, 320×620) +
      `settings` + `playground`. Height raised 520→620 so the menu doesn't scroll.
- [x] **1.5** `capabilities/default.json`: window show/hide/center/focus + store +
      global-shortcut + opener.

## Phase 2 — Platform Abstraction Layer (ADR-001) ✅

- [x] **2.1** `pal/mod.rs`: traits, `PalError`, `detect_session()` (WAYLAND_DISPLAY / XDG).
- [x] **2.2** Win/macOS/X11 adapters: arboard clipboard + enigo input, all `Result`, no panics.
- [x] **2.3** Linux/Wayland adapter: `WaylandClipboard` (wl-clipboard-rs read + persistent
      serve + own-selection cache); input degrades to manual on Wayland.
- [x] **2.4** `Pal::detect()` factory wires adapters from `detect_session()`; in `AppState`.

## Phase 3 — Core flow & clipboard contract (ADR-003/004/005/006) ✅

- [x] **3.1** `AppState { pal, saved_clipboard, busy }` via `app.manage()`.
- [x] **3.2** `trigger_menu_flow`: snapshot original clipboard → state, THEN copy; skip in manual.
- [x] **3.3** `process_inner`: read selection → system prompt → AI → write → hide → paste →
      restore original after delay. (Refactored to take a resolved system prompt.)
- [x] **3.4** AI client: connect (~5s) + total (~60s) timeouts; readable error mapping.
- [x] **3.5** In-flight guard (`try_acquire_busy` / `release_busy`) shared by both commands.
- [x] **3.6** Manual-copy fallback + overlay signal when synthetic unavailable.

## Phase 4 — Configuration system (§5/§6) ✅

- [x] **4.1** `config.rs`: `Settings`/`Profile`/`CustomAction` + `active()`; serde rename/defaults.
- [x] **4.2** Load/save via `tauri-plugin-store`; Rust = source of truth.
- [x] **4.3** Default profiles seeded: **Ollama local** (`gemma4:e4b`, active) **and
      LM Studio** (`http://localhost:1234/v1`).

## Phase 5 — Frontend (§9) ✅

- [x] **5.1** Hash routing: `#/` menu, `#/settings`, `#/playground`.
- [x] **5.2** Menu: actions + translate submenu, ⚙/🧪 buttons, Escape→hide, active destination.
- [x] **5.3** `Settings.tsx`: profiles CRUD, presets, API key, temperature, hotkey, Fetch
      models (dropdown + auto-select), Diagnostics.
- [x] **5.4** Manual-mode UI state (copy-first hint, result/copy view).

## Phase 6 — Hotkey & Wayland integration (§8/§10) ✅

- [x] **6.1** In-process global shortcut (Win/macOS/X11); parse + re-register on change.
      Default **`Ctrl+Shift+A`** (was `Ctrl+Shift+Space`; same combo on every OS).
- [x] **6.2** `single-instance` `--trigger` forwarding into the running daemon.
- [x] **6.3** Hyprland integration documented (autostart + `bind … --trigger`); wired into
      the user's config this session.

## Phase 7 — Observability ✅

- [x] **7.1** `tracing` init (stdout); clipboard/keys never logged. _Rotating file log: TODO._
- [x] **7.2** Settings "Diagnostics" panel: session, clipboard backend, input support, mode.

## Phase 8 — Testing (§12)

- [x] **8.1–8.6** Covered by unit tests + manual verification (hotkey parse, system prompts,
      settings serde/defaults, session detect; freeze/clipboard verified live on Hyprland).
- [ ] **8.7** Full per-platform matrix on **Windows, macOS, Linux/X11** still pending
      (Linux/Wayland path validated here). Release CI now builds all targets.

## Phase 9 — Hardening

- [ ] **9.1** API keys → OS keychain (`keyring`). **DEFERRED** — plaintext `settings.json` for v1.
- [x] **9.2** Streaming responses with live preview ✅ (Playground).
- [x] **9.3** Custom user-defined actions + per-action model overrides ✅.
- [x] **9.4** System tray ✅ (Show menu / Playground / Settings / Quit + left-click). Now uses
      the real app icon.
- [ ] **9.5** Multi-format clipboard snapshot/restore. **DEFERRED** — v1 text-only is enough.

## Phase 10 — Packaging, polish & release (v0.1.x, 2026-06-05) ✅

- [x] **10.1 Keyboard-driven menu** — ↑/↓ (or j/k) navigate, ←/→ change intensity, Enter runs,
      1–9 quick-run, Esc closes; guards so typing in the prompt bar doesn't trigger shortcuts.
- [x] **10.2 Google-style UI redesign** — per-action line icons, a freeform **prompt bar**
      ("Tell GhostPen what to do…" → `process_ai_custom`, pasted back like a preset action),
      and **system (light/dark) theme** via `prefers-color-scheme`.
- [x] **10.3 LM Studio** shipped as a default profile alongside Ollama (OpenAI-compatible).
- [x] **10.4 CLI** — `ghostpen --help` / `--version`, handled before GUI/daemon startup.
- [x] **10.5 App + tray icon** — "nib-ghost" brand mark; `assets/icon.svg` master, full
      `src-tauri/icons/*` regenerated via `tauri icon` (concepts kept in `assets/icon-options/`).
- [x] **10.6 Release CI** — `.github/workflows/release.yml`: on a `v*` tag, build + upload a
      draft GitHub Release for macOS (arm64+x86_64), Windows (x86_64+arm64), Linux
      deb/rpm/appimage (x86_64 + arm64) via tauri-action.
- [x] **10.7 Local install script** — `scripts/install-local.sh` (build via `tauri build` +
      install binary/desktop/icon to ~/.local; avoids the `cargo build` dev-URL pitfall).
- [x] **10.8 Bundle scripts fixed** — `bundle:*` now use `tauri build` (not `tauri bundle`,
      which shipped a stale dev-mode binary).
- [x] **10.9 Freeze fix** — after a manual-mode result the app hung ("not responding") because
      `get_selection` (sync, GTK main thread) read our **own** served Wayland selection and
      deadlocked. `WaylandClipboard` now returns the cached served value while we own the
      selection; a generation counter avoids races between serve threads.
- [x] **10.10 Release v0.1.1** — `git-chglog` config + `CHANGELOG.md`; annotated tags
      `v0.1.0` and `v0.1.1`; version bumped across manifests.
- [x] **10.11 README** — logo + screenshots (action menu / Professional result) captured on a
      real Hyprland session.

## Phase 11 — Live system-audio captions (ADR-008) ✅ (opt-in `captions` feature)

On-device captions/translation for system audio. Native stack gated behind the **`captions`
Cargo feature** (default off) so the default build + release CI are untouched.

- [x] **11.1** Cargo: optional `cpal` + `whisper-rs` behind `[features] captions`; `dirs` for
      the model dir. Default build adds no new system deps.
- [x] **11.2** `captions/audio.rs` — cpal loopback capture (per-OS device pick: Windows WASAPI
      loopback / Linux monitor source / macOS virtual device), downmix→mono + resample→16 kHz,
      capped `SampleBuffer`, dedicated capture thread (non-`Send` `Stream`). No `.unwrap()` on
      OS calls. Unit tests for downmix/resample/buffer cap.
- [x] **11.3** `captions/transcribe.rs` — whisper-rs 0.14 wrapper (auto/pinned language +
      built-in translate flag).
- [x] **11.4** `captions/model.rs` — ggml model path + on-demand bounded download; sanitized id.
- [x] **11.5** `captions/mod.rs` — `CaptionsManager` (in `AppState`): capture + transcription
      worker, `ghostpen://caption` events, optional AI translation via `ai::run_completion`.
      Compiles + degrades gracefully when the feature is off.
- [x] **11.6** `captions` window (transparent, alwaysOnTop, skipTaskbar) + bottom-center
      placement; click-through via `set_ignore_cursor_events`; tray **Captions** item + escape
      hatch event. Commands wired + capabilities widened minimally.
- [x] **11.7** Frontend: `Captions.tsx` overlay, **Live Captions** Settings panel, `api.ts`
      wrappers, `#/captions` route.
- [x] **11.8** Verified: `cargo check` (default) ✅, `cargo check --features captions` ✅,
      `cargo test --features captions` ✅, `npm run build` (tsc) ✅. Runtime capture/transcription
      not exercisable in CI/container (no audio device or display).
- [ ] **11.9** Follow-ups: dedicated release CI lane building `--features captions`
      (+ `libasound2-dev`); overlap/VAD chunking; macOS ScreenCaptureKit to avoid BlackHole.

### Remaining / next
- [ ] **8.7** per-platform test matrix (Windows, macOS, Linux/X11).
- [ ] **6.x** verify the in-process global hotkey on X11/Windows/macOS (Wayland uses the
      compositor bind).
- [ ] **9.1** keychain, **9.5** multi-format clipboard, **7.1** rotating file log (all deferred).
- [ ] Push `main` + tags; let the release workflow publish the first artifacts.
- [ ] Optional: dedicated monochrome tray glyph (dark tile can blend into dark tray bars).

---
*Last updated: 2026-06-05*
