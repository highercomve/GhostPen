# GhostPen on Oriel

GhostPen, AI-driven text editing anywhere on your desktop, ported from Tauri
(Rust) to [Oriel](https://github.com/highercomve/Oriel) (Zig): the first full
application built on Oriel, using only its public `oriel` CLI and API.

Highlight text in any app, press the hotkey (or click the tray icon), pick an
action (proofread, rewrite, translate, …); the result is pasted back in
place. Also: a Playground with streaming answers, text extraction from
clipboard images (OCR through a vision model), live captions of system audio,
and voice dictation. Any OpenAI-compatible endpoint works (Ollama, LM
Studio, OpenAI, OpenRouter, Groq, …; the default is a local Ollama with
`gemma4:e4b`), or GhostPen runs a downloaded model itself: see
[Built-in models](#built-in-models).

The React frontend is GhostPen's own; the commands, events and settings keep
the Tauri version's names and JSON shapes. On first run the Tauri app's
settings are imported, and its downloaded whisper models are reused.

## Build and run

```sh
oriel doctor --fix      # toolchain: Zig, Node.js, ...
oriel dev               # run with hot reload
oriel build             # zig-out/bin/ghostpen-oriel (+ ghostpen-cli)
oriel build -Dcuda      # whisper on an NVIDIA GPU (CUDA toolkit)
oriel package           # deb, rpm, AppImage / setup.exe / .app + .dmg
```

## Using it

| | |
| --- | --- |
| `Ctrl+Shift+A` | Menu for the selected text (hotkeys are editable in Settings) |
| `Ctrl+Shift+D` | Dictation: speak, ⏎ to finish (copied to the clipboard) |
| `Ctrl+Shift+L` | Live captions of what your computer plays |
| Tray icon | Menu, Dictation, Captions, Playground, Settings, Quit |

The same actions from a terminal or a desktop keybinding, handed to the
running instance: `ghostpen-oriel --trigger | --voice-input | --captions |
--settings | --playground`. On Wayland without the GlobalShortcuts portal,
bind these in your compositor, e.g. Hyprland:

```
bind = CTRL SHIFT, A, exec, ghostpen-oriel --trigger
```

`ghostpen-cli` runs an action from the terminal with the same settings:

```sh
echo "teh quick brown fox" | ghostpen-cli proofread
ghostpen-cli translate --lang French --stream "Good morning"
ghostpen-cli profiles
```

## Built-in models

A profile set to **Built-in** runs the model inside GhostPen itself, with the
llama.cpp compiled into it: no Ollama, LM Studio or other server, and
nothing sent over the network. In Settings → Built-in models:

- **Download** one of the catalog models (Qwen3.5 2B/4B/9B, Gemma 3 4B,
  Gemma 4 E4B) from Hugging Face. Downloads can be paused and resumed, and
  are checked against the SHA-256 Hugging Face publishes. They go to
  `<data dir>/GhostPen/models` (`~/.local/share/GhostPen/models` on Linux).
- GGUF files that **LM Studio** (`~/.lmstudio/models`) or **GhostReel**
  (`~/.ghostreel/models`) already downloaded are found and reused, catalog
  or not.
- **Use** points the "Built-in (GhostPen)" profile at a model (creating the
  profile if needed) and makes it active.
- Runner settings: the context window, the GPU (as many layers as its free
  memory holds; the rest runs on the CPU) and how long the model stays
  loaded between actions (10 minutes by default).

The model runs in a helper process (`ghostpen-oriel --llm-helper`, started
and stopped by GhostPen), so a crash or running out of memory can't take
the app down. Build with `-Dcuda` to run it on an NVIDIA GPU; macOS uses
Metal. `ghostpen-cli` uses Built-in profiles too (`ghostpen-cli models`
lists them). Image text extraction still needs a vision endpoint.

Built-in profiles are new to this port: the Tauri app, if it reads the same
settings, sees them as endpoints with no URL.

## Permissions

Declared with `oriel permission add` (see `build.zig`): accessibility
(synthetic copy/paste into other apps; macOS asks on first run), microphone
(dictation) and system audio (captions). On macOS, captions need a loopback
device such as BlackHole.

## Tests

```sh
zig build test            # AI client, settings, images, models
tests/e2e.sh              # headless: select → trigger → Proofread → pasted; Playground streaming
tests/e2e-audio.sh        # headless: captions overlay, dictation → proofread → clipboard
```

The end-to-end tests run on a private X display (Xvfb + D-Bus) against a mock
AI endpoint (`tests/mock_openai.py`); the audio test feeds `tests/speech.wav`
instead of the sound server (`$GHOSTPEN_TEST_AUDIO`).

## Layout

| File | |
| --- | --- |
| `src/main.zig` | Commands, events, the menu flow, windows, tray, hotkeys, launch flags |
| `src/ai.zig` | OpenAI-compatible client: prompts, reasoning-leak retry, SSE streaming, vision, `/models`; local profiles go to `local_llm.zig` |
| `src/local_llm.zig`, `src/llm_helper.zig` | Built-in models: the runner's client (start, idle unload, cancel) and the runner (llama.cpp, JSON lines) |
| `src/llm_models.zig`, `src/chat_format.zig` | Model catalog, resumable verified downloads, models found on disk; prompt formats (Gemma 4/3, ChatML, Qwen thinking) |
| `src/settings.zig`, `src/store.zig` | Settings schema (Tauri-compatible) and the Oriel store |
| `src/captions.zig`, `src/dictation.zig`, `src/models.zig` | Whisper captions and dictation, one shared model |
| `src/image.zig` | PNG helpers for OCR and previews |
| `src/cli.zig` | `ghostpen-cli` |
| `frontend/` | GhostPen's React UI (`src/api.ts` over Oriel's `invoke`/`listen`) |
