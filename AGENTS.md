# AGENTS.md — GhostPen

Canonical instructions for AI coding agents working in this repo. Read this before making
changes. (Symlinked as `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`;
read natively by opencode and Antigravity.)

## What this project is

GhostPen is a cross-platform background daemon that overlays a native-feeling action menu
for AI text editing (proofread, rewrite, concise, translate). Highlight text anywhere →
hotkey → pick action → result pasted back in place. The AI backend is **any
OpenAI-compatible `/chat/completions` endpoint**; the default is a local **Ollama** running
**`gemma4:e4b`**.

## Current state

**Scaffolded (Tauri v2 + React/TS/Vite), implementation in progress.** Build prerequisites
are installed (Rust, Node, Ollama, Tauri system libs). Track progress in
[`.agents/TODO.md`](./.agents/TODO.md). Before writing code, read both of these — they are
the source of truth and override anything you infer:

- [`.agents/plan.md`](./.agents/plan.md) — the implementation plan (stack, steps, code sketches).
- [`.agents/architecture.md`](./.agents/architecture.md) — the governing architecture, ADRs,
  and the plan review. **When the plan and the architecture disagree, the architecture wins**
  (it post-dates and corrects the plan).

## Operating modes — adopt the matching role in `.agents/`

This repo defines two agent roles in `.agents/`. **Before working, decide which mode you are
in and adopt the corresponding role file as your operating instructions:**

- **Planning / design / architecture** → act as the **Architect** defined in
  [`.agents/architect.md`](./.agents/architect.md). Read it and follow its mode detection,
  review process, and output rules. Produce or update `.agents/plan.md` and
  `.agents/architecture.md` (ADRs). When the plan and the architecture disagree, the
  architecture wins.
- **Implementation / coding / bug-fixing** → act as the **Implementer** defined in
  [`.agents/implementer.md`](./.agents/implementer.md). Read it and follow its workflow:
  implement from `.agents/plan.md` + `.agents/architecture.md`, honor the **Critical rules**
  below, and keep `.agents/TODO.md` updated as tasks complete.

If a request spans both (e.g. "design and build X"), do the Architect pass first, get the
plan/architecture settled, then switch to the Implementer role to build it.

## Tech stack

- **Shell/windowing:** Tauri v2 · **Backend:** Rust · **Frontend:** React + TypeScript + Tailwind.
- **AI:** OpenAI-compatible HTTP (`reqwest`). One code path for all providers.
- **OS interaction:** clipboard (`arboard`, Wayland fallback `wl-clipboard-rs`), input
  synthesis (`enigo`, Wayland fallback `ydotool`/`wtype`), hotkey
  (`tauri-plugin-global-shortcut`, Wayland via compositor bind + `tauri-plugin-single-instance`).

## Critical rules (hard-won — do not regress)

These come from the architecture review; violating them reintroduces fixed bugs.

1. **Cross-platform dispatch is runtime, not just compile-time.** A single Linux binary runs
   on both X11 and Wayland. Use `cfg(target_os)` only to separate OS *families*; use the
   runtime `detect_session()` probe (`WAYLAND_DISPLAY` / `XDG_SESSION_TYPE`) to choose
   X11-vs-Wayland behavior. Route all OS interaction through the **Platform Abstraction
   Layer** traits (`Clipboard`, `InputSynth`, `HotkeyBinder`, `Overlay`) — never call an OS
   backend directly from the AI/menu logic.
2. **Clipboard contract — snapshot BEFORE copy.** Save the user's original clipboard in the
   *trigger* step, before synthesizing Ctrl/Cmd+C, into shared `AppState`. Restore it after
   paste. Never treat the selection as "the original clipboard."
3. **Never panic on an OS call.** Every clipboard/input call returns `Result`. No `.unwrap()`
   on `Enigo`/clipboard handles. If synthetic input is unavailable (e.g. Wayland without
   libei), degrade to **manual-copy mode**, don't crash.
4. **Bound every network call.** Build the `reqwest::Client` with a connect timeout (~5 s)
   and total timeout (~30 s, configurable). Surface readable errors; never leave the overlay
   stuck.
5. **Default model is `gemma4:e4b`** (Gemma 4 edge E4B). Don't "correct" it to `gemma3n` —
   it exists on the Ollama library and is verified. (Dev on the Chromebook uses
   `gemma4:31b-cloud` via Ollama Cloud; the Arch desktop can run `gemma4:e4b` locally; shipped
   default stays `gemma4:e4b`.)
6. **Secrets:** API keys live in `settings.json` (plaintext in v1). Never log keys or
   clipboard contents; redact them in errors. Keychain is a planned hardening (`keyring`).
7. **Don't widen Tauri capabilities** beyond what a feature needs (see `capabilities/default.json`).

## Build & run (once scaffolded)

```bash
./scripts/install-deps.sh   # system deps (cross-distro/macOS)
npm install
npm run tauri dev           # development
npm run tauri build         # production binary
```

Default backend setup (Ollama): see [`README.md`](./README.md) — install Ollama, then
`ollama pull gemma4:e4b`.

### Captions feature — auto-detected, no flag to remember (ADR-008)

The system-audio **captions** stack (cpal + whisper.cpp) is an optional Cargo feature
(`captions`, default off) because it needs extra build deps (ALSA, a C/C++ toolchain,
libclang). To avoid typing `--features captions` on every command, `npm run tauri` /
`npm run bundle*` go through [`scripts/tauri.mjs`](./scripts/tauri.mjs), which **probes for
those deps and adds `--features captions` automatically when they're all present**:

- **Arch desktop** (full deps) → captions auto-enabled. A plain `npm run tauri dev` includes
  them.
- **Chromebook/Crostini** (deps absent, and no loopback device anyway — ADR-007) → builds
  cleanly *without* captions; the app degrades to the "compiled without captions" path.
- **CI (`pr-build.yml` + `release.yml`)** → `tauri-action` runs `npm run tauri build`, so it
  **does** go through this wrapper. CI therefore passes `--features <backend>` explicitly per
  target (macOS=`captions-metal`, Linux/Windows-x64=`captions`, GPU lanes per matrix); the
  explicit flag makes the wrapper pass it through instead of auto-detecting. A lane that must
  ship *without* captions (e.g. windows-arm64) sets `GHOSTPEN_CAPTIONS=0` to force the
  auto-detect off. (Earlier this note wrongly claimed release CI bypassed the wrapper — leaving
  `release.yml` with no `--features` made macOS auto-detect a broken CPU build; fixed.)

The same wrapper also **auto-selects the whisper compute backend**: it prefers **CUDA**
(`captions-cuda`) when the CUDA toolkit + an NVIDIA GPU are present, falls back to **Vulkan**
(`captions-vulkan`) when glslc/shaderc + the Vulkan loader exist, and otherwise builds the
**CPU** backend (`captions`). On CUDA it also sets the toolkit env (`CUDA_PATH`, `CUDACXX`,
`CMAKE_CUDA_ARCHITECTURES=native`) so the build finds nvcc even when it's off `PATH`
(e.g. Arch's `/opt/cuda/bin`). GPU whisper is what makes a larger, more accurate model usable
in real time (CPU `tiny` is fast-ish but inaccurate; GPU `small`/`medium` is both).

Force the decision when needed:
- `GHOSTPEN_CAPTIONS=1|0` — captions feature on / off (overrides dep auto-detect).
- `GHOSTPEN_CAPTIONS_GPU=cuda|vulkan|cpu|auto` — pin the backend (default `auto`).

The wrapper prints `[tauri] captions: <feature|off> — <reason>` so you can see what it chose.

## Conventions

- Match the surrounding code's style; keep the menu/AI logic OS-agnostic behind the PAL.
- Validate the two High-risk unknowns with **POC spikes before feature work**: (a) arboard
  clipboard on the target Wayland/Hyprland session, (b) enigo/libei synthetic input there.
  See the architecture Risk Register and Next Steps.
- Update `.agents/architecture.md` (ADRs) when you make a structural decision.
- **Two dev machines** (decide which one you're on before assuming what can be tested):
  - **Arch desktop** (this one) — native Wayland (Hyprland/PipeWire), full build deps. The
    real target: global hotkey, synthetic input, overlay, **and captions** all run here.
    `npm run tauri dev` auto-enables captions (see above).
  - **Chromebook/Crostini VM** — sandboxed (ADR-007): no global-hotkey delivery, no synthetic
    input, no loopback audio. Develop UI + AI + clipboard in **manual-copy mode**; captions
    build out automatically. Validate the "magic" OS integrations on the Arch desktop.
