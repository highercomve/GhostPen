# GhostPen on Oriel

**[Website and downloads](https://highercomve.github.io/GhostPen/)** · [Releases](https://github.com/highercomve/GhostPen/releases) · The earlier Rust/Tauri version: [ghostpen-tauri](https://github.com/highercomve/ghostpen-tauri)

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

![The menu, on the Built-in model](docs/screenshots/menu.png)

| Playground | Settings → Built-in models |
| --- | --- |
| ![Playground](docs/screenshots/playground.png) | ![Built-in models](docs/screenshots/settings-builtin-models.png) |

## Build and run

```sh
oriel doctor --fix      # toolchain: Zig, Node.js, ...
oriel dev               # run with hot reload
oriel build             # zig-out/bin/ghostpen (+ ghostpen-cli)
oriel build -Dcuda      # whisper on an NVIDIA GPU (CUDA toolkit)
oriel build -Dvulkan    # ... or on any GPU through Vulkan (Linux releases are built this way)
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
running instance: `ghostpen --trigger | --voice-input | --captions |
--settings | --playground`. On Wayland without the GlobalShortcuts portal,
bind these in your compositor, e.g. Hyprland:

```
bind = CTRL SHIFT, A, exec, ghostpen --trigger
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

The model runs in a helper process (`ghostpen --llm-helper`, started
and stopped by GhostPen), so a crash or running out of memory can't take
the app down. The Linux releases run it on the GPU through Vulkan (any
vendor; the CPU without a Vulkan driver); build with `-Dcuda` for CUDA on
an NVIDIA GPU; macOS uses Metal. `ghostpen-cli` uses Built-in profiles too (`ghostpen-cli models`
lists them). Image text extraction still needs a vision endpoint.

Built-in profiles are new to this port: the Tauri app, if it reads the same
settings, sees them as endpoints with no URL.

## Compared with the Rust (Tauri) GhostPen

The same app on both stacks: GhostPen's React frontend, the same commands,
settings and prompts. Measured on one Linux machine (Ryzen 7 7800X3D, 16
threads; Arch Linux, Hyprland), Zig 0.16.0 and Rust 1.98.1, both built for
release with whisper on the GPU (CUDA).

![The menu in both versions, on Wayland](docs/screenshots/menu-rust-vs-oriel.png)

On this Wayland desktop the Rust version runs in manual mode (no synthetic
Ctrl+C, so the menu asks you to copy first; in this test it didn't pick up a
manual copy either, and its Playground stopped responding). The Oriel
version copies the selection and pastes the result itself.

| | Rust / Tauri 2 | Zig / Oriel |
| --- | --- | --- |
| Code (app + frontend, generated files excluded) | 6,553 lines (3,737 Rust, 1,926 TS, 890 CSS) | 6,982 lines (3,910 Zig, 2,269 TS, 803 CSS), with Built-in models |
| Dependencies | 627 crates (Cargo.lock) | 2 packages (Oriel, zigimg); Oriel itself has 9 |
| Clean release build ¹ | 229 s (app only; the CLI is a separate build) | 122 s (app, CLI and .deb) |
| Rebuild, nothing changed ² | 26 s | 0.7 s |
| Rebuild after a one-line edit | 25 s | 57 s ³ |
| Build cache | 2.3 GB `target/` + 1.5 GB `~/.cargo/registry` | 0.9 GB (`.zig-cache` 809 MB + global 93 MB) + 281 MB sources (`zig-pkg/`) |
| App binary, stripped | 51.7 MB (whisper and its CUDA kernels inside) | 16.8 MB (whisper **and** llama.cpp) + 40.1 MB `libggml-cuda.so` |
| CLI binary, stripped | 8.2 MB | 1.6 MB |
| Idle memory (PSS, app + WebKit processes) ⁴ | 684 MB (app 270 MB) | 780 MB (app 308 MB) |
| Toolkit (Linux) | GTK 3, WebKitGTK 4.1 | GTK 4, WebKitGTK 6.0 |
| Synthetic copy/paste on Wayland | no (manual mode) | yes (virtual keyboard) |
| Runs AI models itself | no (an endpoint: Ollama, LM Studio, …) | yes: [Built-in models](#built-in-models), or an endpoint |

¹ Empty build caches, dependency sources already downloaded (the Cargo
registry; Zig's `zig-pkg/`). Both include the frontend build and whisper.cpp
with its CUDA kernels; the Oriel build also compiles llama.cpp.
² Rust: `touch` on `main.rs`/`lib.rs` recompiles the crate; Zig caches by
content, so an untouched file costs nothing.
³ Zig compiles the whole app as one unit (and the build also refreshes the
frontend's TypeScript bindings through a debug build), so an edit costs the
full app compile; Rust recompiles only the app crate.
⁴ 20 s after start, idle, on a private X display; both have the CUDA
runtime loaded for whisper.

Packages: the Rust `.deb` is 31.8 MB (app and CLI). The Oriel `.deb` is
19.9 MB, but it doesn't yet include `libggml-cuda.so` (GPU acceleration) or
`ghostpen-cli`, and ships the binary unstripped (72 MB); that's an Oriel
packaging gap being fixed, so package sizes aren't compared yet.

## Transcription server for other tools

`GHOSTPEN_STT_SERVER=1 ghostpen` also serves the whisper model as an
OpenAI-compatible API, so local tools (an agent that receives voice notes,
a video indexer) transcribe through GhostPen's model instead of loading
another: `POST /v1/audio/transcriptions` (multipart `file`, any format
`ffmpeg` reads; `language`; `response_format` json, text, verbose_json with
timestamped segments, srt or vtt), `GET /v1/models`, `GET /health`. It
binds `GHOSTPEN_STT_BIND` (default `0.0.0.0:8771`), serves Settings → Live
Captions' model or `GHOSTPEN_STT_MODEL`, and shares it with captions and
dictation (one copy in memory). Needs `ffmpeg`.

## Updates

Settings → About & updates shows the version, checks for a new release and,
with "Update automatically" on (the default), checks a minute after start
and every 12 hours. The Windows installer, the AppImage and the macOS app
update themselves (the new version starts on the next launch, or with
"Restart now"); deb/rpm installs and source builds only say a new version
exists. Each release publishes a `latest.json` signed with Ed25519 (the
`GHOSTPEN_UPDATE_KEY` secret); GhostPen installs only what matches the public
key in `build.zig`. `GHOSTPEN_UPDATE_MANIFEST=<https url>` checks another
manifest, e.g. to try a release before publishing it.

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
