# TODO — GhostPen Implementation

Ordered, dependency-aware task list derived from [`plan.md`](./plan.md) and
[`architecture.md`](./architecture.md). Work top-to-bottom; phases gate each other.
The Implementer ([`implementer.md`](./implementer.md)) checks items off here as they complete.

**Golden rules while implementing (from architecture Critical rules):** route all OS calls
through the PAL · runtime session detection, not just `cfg!` · snapshot clipboard *before*
copy · never `.unwrap()` an OS handle · bound every network call · default model
`gemma4:e4b` · never log keys/clipboard.

### Dev-environment status (2026-06-04, this machine)
- **Arch/session:** aarch64 Linux, **Wayland** (`wayland-0`), desktop reports `X-Generic`
  (actual compositor = ChromeOS/Sommelier — see Crostini note below; generalize §10's
  Hyprland assumptions for real targets).
- **Toolchain:** Rust 1.96.0 ✅ · Node 24 ✅ · Ollama 0.30.4 ✅ (service active on `:11434`).
  Tauri system deps ✅ (Debian trixie, all present).
- **Model override:** local hardware can't run `gemma4:e4b`, so this machine uses
  **`gemma4:31b-cloud`** (Ollama Cloud, runs server-side; host already authorized — no
  `ollama signin` needed). AI path verified end-to-end via `/v1/chat/completions`.
- **Crostini:** Chromebook/ChromeOS Linux VM → no global hotkey, no synthetic input into
  host apps, no overlay-on-top; clipboard IS shared with ChromeOS. Dev/test in **manual-copy
  mode** (ADR-007); defer the three blocked integrations to a real target.
- **Shipped default stays `gemma4:e4b`** for end users with local GPUs; only this dev
  machine's active profile uses the cloud model.

---

## Phase 0 — POC spikes (validate the High risks BEFORE building) 🚩

> Architecture mandates these first; both are make-or-break for the Wayland target. Do them
> as throwaway spikes, record the outcome in `architecture.md` (update ADR-002 / Open Q's).

- [x] **0.1 Clipboard spike (ADR-002).** ✅ **PASS in Crostini.** `arboard` (default
      features, X11-via-Sommelier) reads *and* writes the clipboard, and reads content
      copied on the **ChromeOS side** — cross-boundary clipboard confirmed. No `wayland`
      feature / `wl-clipboard-rs` needed here. _Re-verify on the real target compositor._
- [ ] **0.2 Input-synthesis spike (§10b, biggest unknown).** **N/A on Crostini** — the VM
      can't synthesize input into host apps, so this defers to a **real target**
      (Hyprland/Wayland, Windows, macOS). On the Chromebook the app runs in **manual-copy
      mode** (ADR-005/007). On the real target: synthesize `Ctrl+C` via `enigo` (libei);
      if it fails, test `ydotool`/`wtype`.
- [ ] **0.3 Overlay spike (ADR open Q3).** **Deferred to real target** (ChromeOS manages
      windows in Crostini). There: compositor window-rules vs `gtk-layer-shell`.

## Phase 1 — Scaffold & dependencies (§4)

- [x] **1.0** Install system deps: `./scripts/install-deps.sh` (cross-distro/macOS;
      `--dry-run` to preview). shellcheck-clean, detects apt/pacman/dnf/zypper/apk/macOS.
      ✅ Ran on this box (Debian trixie/aarch64): all Tauri deps already present.
- [x] **1.1** Scaffolded Tauri v2 + React/TS/Vite; renamed `tauri-app`→`ghostpen`
      (package.json, Cargo.toml pkg + `ghostpen_lib`, tauri.conf productName/title, main.rs).
      _`npm install` runs with the first build._
- [x] **1.2** Plugins added + wired in `lib.rs`: `single-instance` (registered first),
      `store`, `global-shortcut` (+ scaffold `opener`). JS packages added to package.json.
- [x] **1.3** Rust crates added via `cargo add` (newer than plan): **enigo 0.6.1**
      (plan said 0.3 — API differs), **reqwest 0.13.4** (plan said 0.12, +json),
      `arboard 3.6` (all platforms), `tokio` (full), `tracing` + `tracing-subscriber`.
      _`wl-clipboard-rs` Wayland fallback deferred until needed (arboard validated, spike 0.1)._
- [ ] **1.4** Configure `tauri.conf.json` windows (`main` frameless/transparent + `settings`) (§4C).
      _Still the default single 800×600 window._
- [~] **1.5** `capabilities/default.json`: added window show/hide/center/focus + `store` +
      `global-shortcut` permissions. Revisit when the `settings` window is added (1.4).

## Phase 2 — Platform Abstraction Layer (ADR-001)

> This is the spine that makes the app bulletproof across platforms. Build it before the flow.

- [ ] **2.1** `src-tauri/src/pal/mod.rs`: define traits `Clipboard`, `InputSynth`,
      `HotkeyBinder`, `Overlay`, the `PalError` enum, and `detect_session()`
      (`WAYLAND_DISPLAY` / `XDG_SESSION_TYPE`).
- [ ] **2.2** Win/macOS/X11 adapters (known-good): `arboard` clipboard + `enigo` input.
      All methods return `Result`; **no panics**.
- [ ] **2.3** Linux/Wayland adapter informed by spikes: clipboard (arboard or wl-clipboard-rs),
      input (libei/ydotool/wtype chain), `synthetic_supported()` reflects probe result.
- [ ] **2.4** `Pal::select()` factory wires the right adapters from `detect_session()`;
      store in Tauri-managed `AppState`.

## Phase 3 — Core flow & clipboard contract (ADR-003/004/005/006)

- [ ] **3.1** `AppState { pal, saved_clipboard }` registered via `app.manage()`.
- [ ] **3.2** `trigger_menu_flow`: **snapshot original clipboard → state, THEN copy** (fixes
      the save/restore bug). Skip copy in manual mode.
- [ ] **3.3** `process_ai_action`: read selection, build system prompt, call AI, write output,
      hide, paste, then restore the saved original after the configured delay.
- [ ] **3.4** AI client built with connect (~5s) + total (~30s) timeouts; readable error
      mapping; reuse a single `reqwest::Client`.
- [ ] **3.5** Debounce / in-flight guard so overlapping triggers can't corrupt clipboard state.
- [ ] **3.6** Manual-copy fallback path in the command + an overlay signal when
      `synthetic_supported() == false`.

## Phase 4 — Configuration system (§5/§6)

- [ ] **4.1** `config.rs`: `Settings`/`Profile` structs + `active()`; serde rename/defaults.
- [ ] **4.2** Load/save via `tauri-plugin-store` (`settings.json`); Rust `reload()` before
      `get` to avoid JS↔Rust staleness (issue #7).
- [ ] **4.3** Seed default profile = Ollama local, model `gemma4:e4b` (shipped default).
      On **this dev machine**, set the active profile's model to `gemma4:31b-cloud`.

## Phase 5 — Frontend (§9)

- [ ] **5.1** Hash routing: `#/` → menu, `#/settings` → settings.
- [ ] **5.2** `App.tsx` menu: proofread / professional / concise / translate-submenu, ⚙
      Settings, Escape→`hide_window`. Show active destination (e.g. "→ Ollama (local)").
- [ ] **5.3** `Settings.tsx`: profiles CRUD, presets, API key, temperature, hotkey,
      "Fetch models" (`GET /models`) with free-text fallback.
- [ ] **5.4** Manual-mode UI state (instruct copy-first, "Copy result" button).

## Phase 6 — Hotkey & Wayland integration (§8/§10)

- [ ] **6.1** In-process global shortcut for Win/macOS/X11; parse the configured hotkey
      string and re-register on change (lifts §13 future item into v1 if cheap).
- [ ] **6.2** `single-instance` `--trigger` forwarding into the running daemon.
- [ ] **6.3** Ship/generate Hyprland snippets: `exec-once` autostart, `bind … --trigger`,
      and window-rules (or layer-shell from spike 0.3).

## Phase 7 — Observability (architecture §Observability)

- [ ] **7.1** `tracing` to a rotating file log; redact clipboard text + API keys.
- [ ] **7.2** Settings "Diagnostics" panel: detected session, clipboard backend, input
      backend + support, last AI call status.

## Phase 8 — Testing (§12, expanded per-platform)

- [ ] **8.1** Clipboard restored to prior contents after paste (the trust-anchor test).
- [ ] **8.2** Empty/whitespace selection → graceful "No text selected".
- [ ] **8.3** Profile switch (Ollama → OpenAI) routes with correct auth.
- [ ] **8.4** `GET /models` populates dropdown per preset; manual entry on failure.
- [ ] **8.5** API error / non-200 / empty completion → readable message, no paste.
- [ ] **8.6** Escape closes menu; focus-loss auto-hide.
- [ ] **8.7** Run the matrix on **each** target: Windows, macOS (Accessibility granted),
      Linux/X11, Linux/Wayland (spike-validated path).

## Phase 9 — Hardening

- [ ] **9.1** API keys → OS keychain (`keyring`). **DEFERRED** — Crostini has no Secret
      Service/D-Bus keyring backend, so it can't be tested here and would risk the working
      auth flow. Architecture/ADR already accepts plaintext `settings.json` for v1; enable on
      a platform with a keychain (Win/macOS/GNOME/KDE) later.
- [x] **9.2** Streaming responses with live preview ✅ — `process_text_stream` + SSE parser
      (`run_completion_stream`) emits `ghostpen://chunk|done|error`; Playground renders live.
- [x] **9.3** Custom user-defined actions + per-action model overrides ✅ — `CustomAction`
      in settings, `resolve_action()`, managed in Settings, shown in menu + Playground.
- [x] **9.4** System tray ✅ — Show menu / Playground / Settings / Quit + left-click summon.
      Built non-fatally (tray may not render in the ChromeOS shelf under Sommelier; harmless
      Gtk warning). Works on real desktops.
- [ ] **9.5** Multi-format clipboard snapshot/restore (lifts ADR-004 limitation).
      **DEFERRED** — low value; v1 text-only restore is sufficient.

---

## In Progress
- Live functional testing of AI actions (use the Playground window).

## Completed
- **Phase 0.1** clipboard spike (arboard, cross-boundary) ✅
- **Phase 1.0–1.5** deps + scaffold + rename + plugins + crates + window config (main /
  settings / playground) + capabilities ✅
- **First build + launch verified on Crostini** ✅ — dev loop works (Sommelier window).
- **Phase 2 — PAL** ✅ `pal/{mod,clipboard,input}.rs`: traits, `detect_session()`, arboard
  clipboard, enigo input (fallible, probed), `use_synthetic()` (manual on Wayland).
- **Phase 3 — core flow** ✅ AppState, snapshot-before-copy clipboard contract, AI client
  with timeouts, in-flight guard, manual-copy mode. Manual-mode window-hide bug fixed
  (only hide before synthetic paste; keep visible to show result).
- **Phase 4 — config** ✅ Settings/Profile, store load/save (Rust = source of truth),
  defaults seed.
- **Phase 5 — frontend** ✅ hash router, Menu (actions + translate submenu + result/manual
  views), Settings (profiles CRUD, presets, Fetch models → dropdown w/ auto-select,
  temperature, hotkey, force-synthetic, restore delay, Diagnostics).
- **Phase 6 — hotkey** ✅ parse + register on Win/macOS/X11; `--trigger` + single-instance
  forwarding; Wayland no-op (compositor bind per §10).
- **Phase 7 — observability** ✅ tracing init + Diagnostics panel.
- **Playground** ✅ (user request) — dedicated window: input textarea → run any action →
  result textarea (uses `process_text`, no clipboard). 🧪 button in the menu header.
- **Phase 8 — tests** partial ✅ 8 unit tests pass (hotkey parse, system prompts, settings
  serde/defaults, session detect). Per-platform matrix (8.7) still pending on real targets.
- **Fix:** Fetch models now shows a dropdown + auto-selects when the current model isn't
  available (was showing the unreal seeded `gemma4:e4b`).
- **Intensity levels** ✅ — global Subtle / Balanced / Strong control (menu + Playground)
  applied to Professional / Casual / Concise / Expand via leveled system prompts; Proofread
  & Translate ignore it. `level` threaded through all process commands; 2 new tests.

---
*Last updated: 2026-06-04*
