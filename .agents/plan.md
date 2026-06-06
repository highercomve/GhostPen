# GhostPen — Implementation Plan

> A cross-platform background daemon that mimics a native OS context menu for AI-driven
> text editing (proofread, rewrite, summarize, translate). Highlight text anywhere,
> press a hotkey, pick an action, and the result is pasted back in place.

**Status of this document:** master reference, corrected and expanded from the original
draft. Notable changes from v1:
- Renamed to **GhostPen**.
- The AI backend is now **fully configurable** — any OpenAI-compatible API and any model,
  selectable by the user at runtime (local Ollama, OpenAI, OpenRouter, Groq, LM Studio,
  custom endpoints).
- Default model is **`gemma4:e4b`** — Gemma 4, edge family, E4B ("effective 4B")
  variant, verified on the Ollama library (multimodal, 128K context, configurable
  thinking). (An earlier draft of this plan mistakenly "corrected" this to `gemma3n:e4b`
  on the assumption Gemma 4 didn't exist; it does — `ollama pull gemma4:e4b` works.)
- Fixed the Wayland daemon architecture (single-instance arg forwarding).
- Documented the real Wayland constraints (input synthesis, focus, positioning) honestly,
  with mitigations.
- Added clipboard save/restore so the user's clipboard isn't destroyed.

> **Implementation status (2026-06-05) — shipped, released v0.1.1.** This plan is now a
> design reference; the app is built and working. Track live status in [`TODO.md`](./TODO.md).
> Deviations from the sketches below, worth knowing when reading the rest of this doc:
> - **Default hotkey is `Ctrl+Shift+A`**, not `Ctrl+Shift+Space` (same combo on every OS;
>   on Wayland it's bound in the compositor, e.g. Hyprland `bind = CTRL SHIFT, A, exec, ghostpen --trigger`).
> - **Wayland clipboard** is `wl-clipboard-rs` (read + a persistent serve thread), not arboard
>   — arboard is X11-only and loses writes over XWayland. Reading our *own* served selection
>   deadlocks the GTK main thread, so `WaylandClipboard` caches the served value while we own it.
> - **Synthetic input fails silently on native Wayland/Hyprland** (enigo/libei) → app runs in
>   **manual-copy mode** there. Native synthetic paste works on X11/Windows/macOS.
> - **Two default profiles** ship: Ollama (`gemma4:e4b`, active) **and LM Studio**
>   (`:1234`). Any OpenAI-compatible endpoint still works.
> - **Beyond the original plan:** full keyboard-driven menu; Google-style UI (per-action icons
>   + a freeform "prompt bar" → `process_ai_custom`); system light/dark theme; `--help`/
>   `--version`; a "nib-ghost" app/tray icon (`assets/icon.svg`); `scripts/install-local.sh`;
>   and a multi-platform **release workflow** (`.github/workflows/release.yml`) building
>   macOS/Windows/Linux deb·rpm·appimage for x86_64 + arm64.
> - Dev/primary target moved from the Crostini Chromebook to a real **Arch Linux / Hyprland**
>   (Wayland, x86_64) machine, which is why §10's Hyprland assumptions now apply directly.

---

## 1. Architecture

**Tech stack**
- **Framework:** Tauri v2
- **Backend:** Rust (native OS APIs for input simulation + clipboard)
- **Frontend:** React + TypeScript + TailwindCSS
- **AI engine:** any OpenAI-compatible `/chat/completions` endpoint. Default preset is a
  local **Ollama** instance running `gemma4:e4b`.

**Execution flow**
1. User highlights text in any application and presses the configured hotkey
   (default `Ctrl + Shift + Space`).
2. GhostPen saves the current clipboard, then natively simulates `Ctrl+C` and reads the
   selection from the clipboard.
3. A frameless, transparent, always-on-top React window appears.
4. User selects an action (e.g. "Translate → Spanish").
5. Rust builds a strict system prompt and calls the **configured** AI endpoint/model.
6. Rust writes the AI response to the clipboard, hides the UI, simulates `Ctrl+V`,
   then **restores the user's original clipboard** after a short delay.

---

## 2. Platform support matrix (read this before building)

| Capability                     | Windows | macOS | Linux X11 | Linux Wayland |
|--------------------------------|:-------:|:-----:|:---------:|:-------------:|
| Global hotkey (in-process)     | ✅      | ✅    | ✅        | ❌ (use WM bind) |
| Synthetic `Ctrl+C` / `Ctrl+V`  | ✅      | ✅¹   | ✅        | ⚠️ compositor-dependent² |
| Self-position / center window  | ✅      | ✅    | ✅        | ⚠️ needs layer-shell³ |
| Programmatic focus grab        | ✅      | ✅    | ✅        | ⚠️ needs layer-shell³ |
| Clipboard read/write           | ✅      | ✅    | ✅        | ✅ |

¹ macOS requires the app to be granted **Accessibility** permission (System Settings →
Privacy & Security → Accessibility) before input simulation works.
² Wayland blocks synthetic input by design. `enigo` 0.3 can use **libei**, but it only
works if the compositor implements it (Hyprland and recent GNOME/KDE do; many don't).
**This must be verified live on the target session** — see §10.
³ Wayland clients cannot position themselves or grab focus as normal windows. For a
reliable overlay use the **layer-shell** protocol (`gtk-layer-shell` / `wlr-layer-shell`).

**Bottom line:** Windows/macOS work straightforwardly. Wayland is achievable on
compositors that support libei + layer-shell (Hyprland qualifies) but needs the extra
plumbing in §10.

> **Crostini / ChromeOS (current dev machine).** A Chromebook's Linux VM (Wayland via
> Sommelier) is sandboxed: **no** global hotkey, **no** synthetic input into other apps,
> **no** overlay-on-top — but **clipboard read/write works and is shared with ChromeOS**, and
> the app runs/displays. GhostPen therefore runs here in **manual-copy mode** (see
> `architecture.md` ADR-007); the three blocked integrations are validated on a real target.

---

## 3. Prerequisites

For the **default** (local Ollama) preset:

```bash
# Install Ollama from https://ollama.com, then pull the edge model:
ollama pull gemma4:e4b
# (gemma4 = Gemma 4; E4B = "effective 4B" edge variant — multimodal, 128K context)
```

GhostPen works with any other OpenAI-compatible provider too — you just configure the
base URL, API key, and model in Settings (see §5). No prerequisite beyond network access
for cloud providers.

Rust toolchain + Node.js are required to build. On Linux also install the Tauri system
deps (`webkit2gtk`, `libappindicator`, etc. — see the Tauri prerequisites page).

---

## 4. Project initialization & dependencies

### Step A — scaffold

```bash
npm create tauri-app@latest ghostpen
# Selections: React, TypeScript, Vite
cd ghostpen
npm install

# Plugins
npm run tauri add global-shortcut
npm run tauri add store            # persistent settings
npm run tauri add single-instance  # forwards --trigger to the running daemon (Wayland)

# Rust crates
cargo add enigo reqwest serde serde_json tokio --manifest-path src-tauri/Cargo.toml
```

### Step B — `src-tauri/Cargo.toml` dependencies

```toml
[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-global-shortcut = "2"
tauri-plugin-store = "2"
tauri-plugin-single-instance = "2"
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }

[dependencies.enigo]
version = "0.3"
# Wayland support is gated behind libei at runtime; x11 is the X11 backend.
features = ["wayland", "x11"]

[target.'cfg(any(target_os = "windows", target_os = "macos"))'.dependencies]
arboard = "3"

[target.'cfg(target_os = "linux")'.dependencies]
wl-clipboard-rs = "0.8"
```

### Step C — `src-tauri/tauri.conf.json` windows

Two windows: the frameless menu (`main`) and a normal settings window (`settings`,
created on demand / hidden initially).

```json
{
  "app": {
    "windows": [
      {
        "label": "main",
        "title": "GhostPen",
        "width": 280,
        "height": 340,
        "decorations": false,
        "transparent": true,
        "alwaysOnTop": true,
        "skipTaskbar": true,
        "visible": false,
        "resizable": false
      },
      {
        "label": "settings",
        "title": "GhostPen Settings",
        "url": "index.html#/settings",
        "width": 460,
        "height": 560,
        "decorations": true,
        "transparent": false,
        "visible": false,
        "resizable": true
      }
    ]
  }
}
```

> On Linux, `transparent: true` requires a running compositor (true on Wayland and on
> X11 with a compositor). macOS transparency may require `macOSPrivateApi: true` in
> `tauri.conf.json` depending on the effect you want.

### Step D — `src-tauri/capabilities/default.json`

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "windows": ["main", "settings"],
  "permissions": [
    "core:default",
    "core:window:allow-show",
    "core:window:allow-hide",
    "core:window:allow-center",
    "core:window:allow-set-focus",
    "global-shortcut:allow-register",
    "global-shortcut:allow-unregister",
    "store:default"
  ]
}
```

---

## 5. Configuration system (the configurable AI backend)

This is the core new feature. GhostPen talks to **any OpenAI-compatible chat endpoint**.

### Config schema

Persisted as JSON via `tauri-plugin-store` in the app config dir
(`settings.json`). The shape:

```jsonc
{
  "hotkey": "Ctrl+Shift+Space",
  "activeProfileId": "ollama-local",
  "profiles": [
    {
      "id": "ollama-local",
      "name": "Ollama (local)",
      "baseUrl": "http://localhost:11434/v1",  // note: includes /v1
      "apiKey": "",                              // empty = no Authorization header
      "model": "gemma4:e4b",
      "temperature": 0.2
    },
    {
      "id": "openai",
      "name": "OpenAI",
      "baseUrl": "https://api.openai.com/v1",
      "apiKey": "sk-...",
      "model": "gpt-4o-mini",
      "temperature": 0.2
    }
  ]
}
```

**Built-in presets** the Settings UI offers as a starting point (user can edit/add/remove):

| Preset      | baseUrl                              | Key needed | Example model       |
|-------------|--------------------------------------|:----------:|---------------------|
| Ollama      | `http://localhost:11434/v1`          | no         | `gemma4:e4b`        |
| LM Studio   | `http://localhost:1234/v1`           | no         | (local model id)    |
| OpenAI      | `https://api.openai.com/v1`          | yes        | `gpt-4o-mini`       |
| OpenRouter  | `https://openrouter.ai/api/v1`       | yes        | `google/gemma-3...` |
| Groq        | `https://api.groq.com/openai/v1`     | yes        | `llama-3.3-70b`     |
| Custom      | (user-entered)                       | maybe      | (user-entered)      |

Because every provider above speaks the same `/chat/completions` schema, **one client
code path covers all of them** — the only differences are `baseUrl`, the optional
`Authorization: Bearer <key>` header, and the model id.

### Model discovery

The Settings UI populates a model dropdown by calling the provider's `GET /models`
endpoint (OpenAI-compatible — Ollama, LM Studio, OpenAI, OpenRouter, Groq all support it),
returning `{ "data": [{ "id": "..." }, ...] }`. If the call fails, the user can type the
model id manually.

> Security note: API keys live in `settings.json` in plaintext by default. For a v1 this
> is acceptable; a hardening pass can move keys to the OS keychain via the `keyring` crate.
> Document this clearly to the user.

---

## 6. Backend — `src-tauri/src/config.rs`

Load/save settings and resolve the active profile. (Sketch — adapt to the store API.)

```rust
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    #[serde(default, rename = "apiKey")]
    pub api_key: String,
    pub model: String,
    #[serde(default = "default_temp")]
    pub temperature: f32,
}
fn default_temp() -> f32 { 0.2 }

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
    #[serde(rename = "activeProfileId")]
    pub active_profile_id: String,
    pub profiles: Vec<Profile>,
}
fn default_hotkey() -> String { "Ctrl+Shift+Space".into() }

impl Settings {
    pub fn active(&self) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.id == self.active_profile_id)
    }
}
```

Persistence is via `tauri-plugin-store` (read/write `settings.json`). The frontend Settings
view reads/writes the same store directly through the JS store API, so Rust and JS share
one source of truth.

---

## 7. Backend — `src-tauri/src/hardware.rs`

Adds clipboard **save/restore** so the user's clipboard survives the operation.

```rust
use enigo::{Direction, Enigo, Key, Keyboard, Settings as EnigoSettings};
use std::thread;
use std::time::Duration;

fn modifier() -> Key {
    if cfg!(target_os = "macos") { Key::Meta } else { Key::Control }
}

pub fn simulate_copy() {
    let mut enigo = Enigo::new(&EnigoSettings::default()).unwrap();
    let _ = enigo.key(modifier(), Direction::Press);
    let _ = enigo.key(Key::Unicode('c'), Direction::Click);
    let _ = enigo.key(modifier(), Direction::Release);
    thread::sleep(Duration::from_millis(80)); // allow the source app to populate the clipboard
}

pub fn simulate_paste() {
    let mut enigo = Enigo::new(&EnigoSettings::default()).unwrap();
    let _ = enigo.key(modifier(), Direction::Press);
    let _ = enigo.key(Key::Unicode('v'), Direction::Click);
    let _ = enigo.key(modifier(), Direction::Release);
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
pub fn read_clipboard() -> String {
    use arboard::Clipboard;
    Clipboard::new().and_then(|mut c| c.get_text()).unwrap_or_default()
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
pub fn write_clipboard(text: &str) {
    use arboard::Clipboard;
    if let Ok(mut c) = Clipboard::new() { let _ = c.set_text(text.to_string()); }
}

#[cfg(target_os = "linux")]
pub fn read_clipboard() -> String {
    use std::io::Read;
    use wl_clipboard_rs::paste::{get_contents, ClipboardType, MimeType, Seat};
    match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Text) {
        Ok((mut pipe, _)) => {
            let mut buf = vec![];
            let _ = pipe.read_to_end(&mut buf);
            String::from_utf8_lossy(&buf).into_owned()
        }
        Err(_) => String::new(),
    }
}

#[cfg(target_os = "linux")]
pub fn write_clipboard(text: &str) {
    use wl_clipboard_rs::copy::{MimeType, Options, Source};
    let opts = Options::new();
    let _ = opts.copy(Source::Bytes(text.as_bytes().into()), MimeType::Text);
}
```

> **Superseded by `architecture.md` (ADR-001/002/003/005).** This `cfg`-split sketch has two
> bugs the architecture fixes: (a) `wl-clipboard-rs` is gated to all of Linux but only works
> on Wayland — X11 breaks; use `arboard` everywhere with a runtime Wayland fallback.
> (b) the save/restore snapshots the *selection*, not the original clipboard — snapshot
> **before** `simulate_copy`. Also: never `.unwrap()` `Enigo::new()`; return `Result` and
> degrade to manual-copy mode. Route everything through the Platform Abstraction Layer.

---

## 8. Backend — `src-tauri/src/lib.rs`

Generic OpenAI-compatible client + single-instance daemon + hotkey/trigger flow.

```rust
pub mod config;
pub mod hardware;

use serde_json::json;
use tauri::{AppHandle, Manager};
use tauri_plugin_store::StoreExt;

fn load_settings(app: &AppHandle) -> Result<config::Settings, String> {
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    let val = store.get("settings").ok_or("No settings saved yet")?;
    serde_json::from_value(val).map_err(|e| e.to_string())
}

fn system_prompt(action: &str, target_lang: Option<String>) -> Result<String, String> {
    Ok(match action {
        "proofread" => "Fix all spelling, grammar, syntax, and punctuation errors. Maintain the original tone. Return ONLY the finalized text. No conversational filler, notes, or wrapper quotes.".into(),
        "professional" => "Rewrite the text to be professional, polite, and clear. Return ONLY the rewritten text, with no explanations.".into(),
        "concise" => "Condense the text to be short and precise while preserving all core information. Return ONLY the condensed text.".into(),
        "translate" => {
            let lang = target_lang.unwrap_or_else(|| "English".into());
            format!("Auto-detect the source language. Translate the text into natural, fluent {lang}, preserving formatting and tone. Return ONLY the translated text — no filler, explanations, or quotes.")
        }
        _ => return Err("Invalid action".into()),
    })
}

#[tauri::command]
async fn hide_window(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") { let _ = w.hide(); }
}

#[tauri::command]
async fn open_settings(app: AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[tauri::command]
async fn process_ai_action(
    action: String,
    target_lang: Option<String>,
    app: AppHandle,
) -> Result<(), String> {
    let settings = load_settings(&app)?;
    let profile = settings.active().ok_or("No active AI profile configured")?.clone();

    let selected = hardware::read_clipboard();
    if selected.trim().is_empty() {
        return Err("No text selected".into());
    }
    let original_clipboard = selected.clone(); // for restore later

    let prompt = system_prompt(&action, target_lang)?;

    let client = reqwest::Client::new();
    let mut req = client
        .post(format!("{}/chat/completions", profile.base_url.trim_end_matches('/')))
        .json(&json!({
            "model": profile.model,
            "messages": [
                { "role": "system", "content": prompt },
                { "role": "user", "content": selected }
            ],
            "temperature": profile.temperature,
            "stream": false
        }));
    if !profile.api_key.is_empty() {
        req = req.bearer_auth(&profile.api_key);
    }

    let resp = req.send().await.map_err(|e| format!("API error: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("API returned {}", resp.status()));
    }
    let data: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    let output = data["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_string();
    if output.is_empty() {
        return Err("Model returned empty output".into());
    }

    hardware::write_clipboard(&output);
    if let Some(w) = app.get_webview_window("main") { let _ = w.hide(); }
    hardware::simulate_paste();

    // Restore the user's original clipboard after the paste lands.
    let app2 = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(300));
        let _ = &app2;
        hardware::write_clipboard(&original_clipboard);
    });

    Ok(())
}

fn trigger_menu_flow(app: &AppHandle) {
    hardware::simulate_copy();
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.center();   // honored on Win/macOS/X11; see §10 for Wayland
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // single-instance: a second launch (e.g. WM-bound `ghostpen --trigger`) does NOT
        // start a new process — its args are forwarded here into the running daemon.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if argv.iter().any(|a| a == "--trigger") {
                trigger_menu_flow(&app.clone());
            }
        }))
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            // First-launch with --trigger (rare; usually the daemon is already running).
            if std::env::args().any(|a| a == "--trigger") {
                trigger_menu_flow(&app.handle().clone());
            }

            // In-process global shortcut works on Windows / macOS / X11, NOT Wayland.
            #[cfg(any(target_os = "windows", target_os = "macos"))]
            {
                use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
                let handle = app.handle().clone();
                let hotkey = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Space);
                app.global_shortcut().on_shortcut(hotkey, move |_, _, state| {
                    if state.state() == ShortcutState::Pressed {
                        trigger_menu_flow(&handle);
                    }
                })?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            process_ai_action,
            hide_window,
            open_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running GhostPen");
}
```

> Note: the hotkey above is hard-coded for clarity. To honor the configurable `hotkey`
> string from settings, parse it into `Modifiers`/`Code` at setup and re-register when the
> user changes it. Add that once the static version works.
>
> **Superseded by `architecture.md` (ADR-003/006).** Snapshot the original clipboard in
> `trigger_menu_flow` *before* `simulate_copy` (into shared `AppState`), and restore from
> that — the sketch above restores the selection, not the original. Build the `reqwest`
> client with connect/total timeouts so a hung endpoint can't freeze the overlay.

---

## 9. Frontend

### 9.1 Routing
Use a tiny hash router (or `react-router`) so `index.html#/` renders the menu and
`index.html#/settings` renders the settings window.

### 9.2 `src/App.tsx` — the menu
Same structure as the v1 draft (proofread / professional / concise / translate-submenu),
plus a small **⚙ Settings** affordance that calls `invoke('open_settings')`. Keep the
`Escape` handler that calls `invoke('hide_window')`.

The action handlers are unchanged from v1 — they call:
```ts
await invoke('process_ai_action', { action: actionId, targetLang: targetLang ?? null });
```
The model/provider is resolved entirely in Rust from the active profile, so the menu
component needs no AI config knowledge.

### 9.3 `src/Settings.tsx` — the configurable backend UI
- Loads/saves the config (§5) via the JS `@tauri-apps/plugin-store` API (`settings.json`).
- Lets the user: pick the **active profile**; add/edit/delete profiles; choose a **preset**
  to prefill `baseUrl`; enter **API key**; set **temperature**; and choose the **hotkey**.
- **Model picker:** a "Fetch models" button does `GET {baseUrl}/models`
  (with `Authorization` if a key is set), then populates a dropdown from `data[].id`. Falls
  back to a free-text input if the request fails.
- Persists on change; Rust reads the same store on each action.

---

## 10. Wayland / Hyprland specifics

The three Wayland blockers and their mitigations:

**(a) Global hotkey — bind it in the compositor.**
The in-process global-shortcut plugin doesn't work on Wayland. Instead bind the key in
Hyprland to launch GhostPen with `--trigger`. Thanks to `tauri-plugin-single-instance`,
this forwards the trigger into the already-running daemon (no new process, no cold start):

```ini
# ~/.config/hypr/hyprland.conf   (NOTE: hypr, not hyprland)
bind = CTRL SHIFT, Space, exec, /path/to/ghostpen --trigger
```
Make sure GhostPen is started once at login (e.g. `exec-once = /path/to/ghostpen`).

**(b) Input synthesis (`Ctrl+C`/`Ctrl+V`) — verify libei live.**
`enigo` on Wayland needs the compositor's libei support. Before building the full app,
run a 20-line spike: simulate `Ctrl+C` and check whether the clipboard changes on your
Hyprland session. If it doesn't, fallbacks are: (i) require the user to copy manually
before the hotkey, or (ii) use `wtype`/`ydotool` (the latter needs a uinput daemon).
**Treat this as the project's biggest unknown.**

**(c) Self-positioning & focus — use layer-shell for the overlay.**
`window.center()` / `set_focus()` are not reliably honored for ordinary Wayland surfaces.
For a dependable centered, focused overlay, render `main` as a **layer-shell** surface
(`gtk-layer-shell`). This is extra integration work; an acceptable v1 compromise is to let
the compositor place the window and add a Hyprland window rule to center + focus it:
```ini
windowrulev2 = float, title:^(GhostPen)$
windowrulev2 = center, title:^(GhostPen)$
windowrulev2 = stayfocused, title:^(GhostPen)$
```

---

## 11. Execution instructions

**Windows / macOS**
```bash
npm run tauri dev
```
Select text anywhere, press `Ctrl+Shift+Space`. On macOS, grant **Accessibility**
permission first, or input simulation silently fails.

**Linux X11** — same as above (in-process hotkey works).

**Linux Wayland / Hyprland**
1. Build: `npm run tauri build` (or run `dev` for iteration).
2. Autostart the daemon: `exec-once = /path/to/ghostpen` in `~/.config/hypr/hyprland.conf`.
3. Bind the trigger: `bind = CTRL SHIFT, Space, exec, /path/to/ghostpen --trigger`.
4. Reload Hyprland, verify the libei spike (§10b) works.

---

## 12. Testing checklist
- [ ] §10b libei spike passes on the target Wayland session (or fallback chosen).
- [ ] Clipboard is restored to its prior contents after a paste.
- [ ] Empty/whitespace selection shows a graceful "No text selected" error.
- [ ] Switching active profile (Ollama → OpenAI) routes the request correctly with auth.
- [ ] `GET /models` populates the dropdown for each preset; manual entry works on failure.
- [ ] API error / non-200 / empty completion each surface a readable message and don't paste.
- [ ] Escape closes the menu; menu loses focus → optionally auto-hides.

## 13. Future hardening
- Move API keys to the OS keychain (`keyring` crate) instead of plaintext `settings.json`.
- Streaming responses with a live preview before paste.
- Configurable/custom actions (user-defined prompts) and per-action model overrides.
- System tray icon with quick profile switch + quit.
- Make the hotkey fully dynamic (parse the configured string and re-register).

---

## 14. Implementation TODO

The ordered, dependency-aware task list lives in [`TODO.md`](./TODO.md). It sequences the
work into phases — **POC spikes first** (clipboard + input synthesis on the target Wayland
session), then scaffold → Platform Abstraction Layer → core flow/clipboard contract →
config → frontend → hotkey/Wayland → observability → per-platform testing → hardening.

Implementation should follow `TODO.md` top-to-bottom, honoring the corrections in
[`architecture.md`](./architecture.md) (which wins on any conflict with this plan).

---

## 15. Live system-audio captions (ADR-008)

A second feature alongside text editing: **live captions + translation for system audio**
(meetings, videos, podcasts). Governed by **ADR-008** in `architecture.md`.

**Pipeline:** loopback capture (`cpal`) → on-device transcription (`whisper-rs`/whisper.cpp)
→ *optional* AI translation (the active OpenAI-compatible profile) → a transparent,
click-through captions overlay window.

**Build flag.** The native stack (cpal + whisper-rs) is behind the **optional `captions`
Cargo feature** — default **off** so the default build and the 6-target release CI add no new
system deps. Enable with `cargo build --features captions` /
`npm run tauri build -- --features captions`. Linux additionally needs `libasound2-dev`
(ALSA) and a C/C++ toolchain + `libclang` at build time. Compiled out, the overlay/commands
exist but `captions_start` reports "compiled without captions support" (no crash).

**Backend (`src-tauri/src/captions/`).**
- `audio.rs` — cpal loopback capture behind a small port. Per-OS device pick (Windows WASAPI
  loopback on the default output device; Linux PipeWire/PulseAudio *monitor* source; macOS a
  user-installed virtual device, e.g. BlackHole). Downmix→mono + linear resample→16 kHz in the
  callback. The non-`Send` `Stream` lives on a dedicated capture thread.
- `transcribe.rs` — whisper-rs 0.14 wrapper (`auto`/pinned language, built-in translate flag).
- `model.rs` — resolve/download ggml models (`ggml-{id}.bin`) into the app data dir; bounded
  HTTP; path-sanitized model id.
- `mod.rs` — `CaptionsManager` (in `AppState`) orchestrates capture + a transcription worker
  thread, emits `ghostpen://caption` events, and does optional AI translation via
  `ai::run_completion`.

**Overlay + commands.** New `captions` window (`#/captions`), transparent + alwaysOnTop +
skipTaskbar. Click-through via `set_ignore_cursor_events` ("ghost" mode); the tray **Captions**
item / `open_captions` always re-enables interaction and emits `ghostpen://captions-show`.
Commands: `open_captions`, `captions_status`, `captions_list_devices`, `captions_start`,
`captions_stop`, `captions_set_click_through`, `captions_download_model`.

**Frontend.** `Captions.tsx` overlay (rolling lines, start/stop, ghost toggle), a **Live
Captions** panel in `Settings.tsx` (model + download, source language, Whisper/AI translate,
target language, chunk length, capture device, font size), and `api.ts` wrappers.

**v1 limitations.** Fixed-window chunking (default 5 s) can clip words at boundaries
(overlap/VAD later); macOS needs a virtual loopback device; releasing captions binaries needs
a dedicated CI lane with `--features captions` + ALSA dev libs.
