# GhostPen

A cross-platform desktop app for AI-driven text editing. Highlight text anywhere, trigger
GhostPen, pick an action (proofread, rewrite, translate, …), and the result is pasted back
in place — or transform text directly in the built-in **Playground**.

GhostPen talks to **any OpenAI-compatible `/chat/completions` endpoint** (Ollama, OpenAI,
OpenRouter, Groq, LM Studio, or a custom endpoint). The default, zero-config setup runs a
**local Ollama** instance, so your text never leaves your machine.

Built with **Tauri v2** (Rust backend + React/TypeScript frontend).

> Design docs: [`.agents/plan.md`](./.agents/plan.md) (implementation plan),
> [`.agents/architecture.md`](./.agents/architecture.md) (architecture + ADRs),
> [`.agents/TODO.md`](./.agents/TODO.md) (build status).

---

## Features

- **Rewrite actions:** Proofread · Professional · Casual · Concise · Expand · Translate (12 languages).
- **Intensity levels:** a global **Subtle / Balanced / Strong** control tunes how far the
  tone/length actions go (Professional, Casual, Concise, Expand).
- **Custom actions:** define your own action with a custom prompt and optional per-action
  model override — it shows up in the menu and Playground.
- **Playground:** a window to type/paste text, run any action, and watch the result **stream
  in live** — no clipboard needed.
- **Configurable backends:** multiple AI **profiles** (provider, base URL, API key, model,
  temperature); switch the active one anytime. Built-in presets + `GET /models` discovery.
- **Clipboard-safe:** your original clipboard is snapshotted before the operation and
  restored afterward.
- **Cross-platform input:** native global hotkey + synthetic copy/paste on Windows/macOS/X11;
  a **manual-copy mode** fallback where synthetic input isn't available (e.g. Wayland).
- **System tray** (where supported): Show menu · Playground · Settings · Quit.

---

## Prerequisites

### 1. Build toolchain

- **Rust** (stable) and **Node.js** (LTS) — install Rust via [rustup](https://rustup.rs) and
  Node from [nodejs.org](https://nodejs.org).
- **System libraries** (webkit, appindicator, xdo, …): use the cross-platform installer,
  which detects your OS/distro and installs the right packages:
  ```bash
  ./scripts/install-deps.sh            # apt / pacman / dnf / zypper / apk / macOS
  ./scripts/install-deps.sh --dry-run  # preview without installing
  ```
  It does **not** install Rust/Node (it checks for them and prints how to get them). For the
  manual list, see the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

### 2. An AI backend

**Default — Ollama (local, recommended).** GhostPen's default profile points at a local
Ollama server. Install Ollama and pull a model:

| Platform | Install Ollama |
|----------|----------------|
| **macOS** | App from <https://ollama.com/download>, or `brew install ollama` |
| **Linux** | `curl -fsSL https://ollama.com/install.sh \| sh` |
| **Windows** | Installer from <https://ollama.com/download> |

```bash
ollama pull gemma4:e4b        # the shipped default model
ollama run gemma4:e4b "hi"    # verify it works
```

Ollama listens on `http://localhost:11434`, which matches GhostPen's built-in Ollama profile
(`http://localhost:11434/v1`). No API key required. To use a different model, pull it and
select it in **Settings → Model** (the **Fetch models** button lists what's available).

> **No local GPU?** Use an [Ollama Cloud](https://ollama.com) model such as
> `gemma4:31b-cloud` (runs server-side, same local endpoint), or any cloud provider below.

**Other backends (optional)** — no install needed, just configure in **Settings**:

| Provider   | Base URL                          | API key |
|------------|-----------------------------------|:-------:|
| OpenAI     | `https://api.openai.com/v1`       | yes     |
| OpenRouter | `https://openrouter.ai/api/v1`    | yes     |
| Groq       | `https://api.groq.com/openai/v1`  | yes     |
| LM Studio  | `http://localhost:1234/v1`        | no      |

---

## Build & run

```bash
git clone <repo-url> ghostpen && cd ghostpen
./scripts/install-deps.sh      # system libraries
npm install                    # JS dependencies

npm run tauri dev              # run in development (hot reload)
npm run tauri build            # production bundles → src-tauri/target/release/bundle/
```

Run the backend tests with:

```bash
cargo test --manifest-path src-tauri/Cargo.toml
```

---

## Usage

### Triggering the menu

- **Windows / macOS / Linux (X11):** select text in any app and press the global hotkey
  (default **`Ctrl + Shift + Space`**, configurable in Settings). On **macOS**, grant
  **Accessibility** permission first (System Settings → Privacy & Security → Accessibility),
  or input simulation silently fails.
- **Linux (Wayland / Hyprland):** in-process global hotkeys aren't allowed; bind a key in
  your compositor to launch GhostPen with `--trigger` (single-instance forwards it to the
  running app), and autostart the daemon. See [`.agents/plan.md` §10](./.agents/plan.md) for
  the exact Hyprland snippets. Without synthetic input, GhostPen runs in **manual-copy mode**:
  copy your text (Ctrl+C) first, pick an action, then paste the result (Ctrl+V).

### CLI flags

A second launch with a flag is forwarded into the running instance (no new process):

```bash
ghostpen --trigger      # show the action menu
ghostpen --playground   # open the Playground window
ghostpen --settings     # open the Settings window
```

### Actions & intensity

Pick an action from the menu or Playground. The **Intensity** control (Subtle / Balanced /
Strong) applies to Professional, Casual, Concise, and Expand. Proofread and Translate ignore
it. **Translate** opens a language submenu.

### Playground

Open with the **🧪** button (or `--playground`). Type or paste text, choose an intensity and
an action, and the result streams in live. Use **Copy result**, **Use as input** (to chain
transforms), or **Clear**.

### Custom actions

**Settings → Custom Actions → + Add.** Give it a label and a system prompt (e.g. *"Convert
the text into concise bullet points. Return ONLY the bullets."*), optionally a model
override. It appears alongside the built-in actions in the menu and Playground.

---

## Platform support

| Capability | Windows | macOS | Linux X11 | Linux Wayland |
|---|:--:|:--:|:--:|:--:|
| Global hotkey (in-process) | ✅ | ✅ | ✅ | ❌ (bind in compositor → `--trigger`) |
| Synthetic copy / paste | ✅ | ✅¹ | ✅ | ⚠️ libei-dependent → manual-copy mode |
| Clipboard read/write | ✅ | ✅ | ✅ | ✅ |
| System tray | ✅ | ✅ | ✅ | ✅² |

¹ Requires macOS **Accessibility** permission.
² Tray rendering depends on the desktop environment.

> **ChromeOS / Crostini:** runs as a development/manual-mode target — the clipboard is shared
> with ChromeOS, but global hotkeys and synthetic input into host apps aren't available, so
> use the **Playground** or manual-copy mode.

---

## Configuration & privacy

Settings (profiles, endpoints, API keys, hotkey, intensity, custom actions, restore delay)
are stored as JSON in the app config directory (`settings.json`) via `tauri-plugin-store`.

- **API keys are stored in plaintext** in `settings.json` for v1. Moving them to the OS
  keychain is planned hardening — see `.agents/architecture.md`.
- Selected text is sent to whichever provider the **active profile** points at; the menu
  shows the active destination so you don't send text to a cloud provider unintentionally.
- With the default local Ollama profile, **nothing leaves your machine**.

---

## Project layout

```
src/             React + TypeScript frontend (Menu, Settings, Playground, LevelBar)
src-tauri/src/   Rust backend
  ├── lib.rs       app wiring, commands, hotkey, tray, trigger flow
  ├── pal/         Platform Abstraction Layer (clipboard, input, session detection)
  ├── config.rs    settings / profiles / custom actions
  └── ai.rs        OpenAI-compatible client (+ streaming, model discovery)
scripts/         install-deps.sh (cross-platform system deps)
.agents/         design docs: plan, architecture, TODO, agent roles
```
