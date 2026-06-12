// GhostPen — backend entrypoint.
//
// Wires the Platform Abstraction Layer, the OpenAI-compatible AI client, the configurable
// settings, and the trigger/clipboard flow. See .agents/architecture.md for the ADRs that
// govern this code (PAL, snapshot-before-copy, no-panic OS calls, bounded HTTP, manual mode).

pub mod ai;
pub mod captions;
pub mod config;
pub mod dictation;
pub mod pal;

use pal::Pal;
use serde::Serialize;
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_store::StoreExt;

// ---- shared state --------------------------------------------------------------------

struct AppState {
    pal: Mutex<Pal>,
    /// The user's clipboard, snapshotted BEFORE synthetic copy, restored after paste (ADR-003).
    saved_clipboard: Mutex<Option<String>>,
    /// Guards against overlapping triggers corrupting clipboard state.
    busy: Mutex<bool>,
    /// Live system-audio captions subsystem (ADR-008).
    captions: captions::CaptionsManager,
    /// Voice dictation subsystem (ADR-009).
    dictation: dictation::DictationManager,
}

impl AppState {
    fn new() -> Self {
        AppState {
            pal: Mutex::new(Pal::detect()),
            saved_clipboard: Mutex::new(None),
            busy: Mutex::new(false),
            captions: captions::CaptionsManager::new(),
            dictation: dictation::DictationManager::new(),
        }
    }
}

/// Lock a mutex, recovering the guard if another thread poisoned it by panicking
/// while holding it. The guarded values here are OS handles (PAL clipboard/input)
/// and small flags; a prior panic doesn't corrupt them in any way that matters for
/// the next clipboard op, and crashing the whole daemon (the `.unwrap()` default)
/// is strictly worse. Honors Critical Rule #3 — never panic on an OS call.
fn lock_recover<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

// ---- DTOs returned to the frontend ---------------------------------------------------

#[derive(Serialize)]
struct ProcessResult {
    output: String,
    /// true → GhostPen pasted it for you; false → it's on the clipboard, paste manually.
    pasted: bool,
    manual: bool,
}

#[derive(Serialize)]
struct Status {
    session: String,
    clipboard_backend: String,
    input_available: bool,
    use_synthetic: bool,
    manual_mode: bool,
    active_profile: String,
    active_model: String,
}

// ---- settings persistence (Rust = source of truth) ----------------------------------

fn load_settings(app: &AppHandle) -> config::Settings {
    match app.store("settings.json") {
        Ok(store) => store
            .get("settings")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_else(config::Settings::defaults),
        Err(_) => config::Settings::defaults(),
    }
}

fn persist_settings(app: &AppHandle, settings: &config::Settings) -> Result<(), String> {
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    let value = serde_json::to_value(settings).map_err(|e| e.to_string())?;
    store.set("settings", value);
    store.save().map_err(|e| e.to_string())?;
    Ok(())
}

// ---- hotkey --------------------------------------------------------------------------

fn token_to_code(tok: &str) -> Option<Code> {
    let name = match tok.to_ascii_lowercase().as_str() {
        "space" => "Space".to_string(),
        "enter" | "return" => "Enter".to_string(),
        "tab" => "Tab".to_string(),
        other if other.chars().count() == 1 => {
            let c = other.chars().next().unwrap();
            if c.is_ascii_alphabetic() {
                format!("Key{}", c.to_ascii_uppercase())
            } else if c.is_ascii_digit() {
                format!("Digit{c}")
            } else {
                return None;
            }
        }
        _ => return None,
    };
    name.parse::<Code>().ok()
}

fn parse_hotkey(s: &str) -> Option<Shortcut> {
    let mut mods = Modifiers::empty();
    let mut code: Option<Code> = None;
    for part in s.split('+') {
        match part.trim().to_ascii_lowercase().as_str() {
            "ctrl" | "control" => mods |= Modifiers::CONTROL,
            "shift" => mods |= Modifiers::SHIFT,
            "alt" | "option" => mods |= Modifiers::ALT,
            "super" | "meta" | "cmd" | "command" | "win" => mods |= Modifiers::SUPER,
            other => code = token_to_code(other),
        }
    }
    code.map(|c| Shortcut::new(Some(mods), c))
}

/// Register the in-process global hotkey (Windows/macOS/X11). On Wayland this is a no-op
/// (returns `Ok`) — bind the key in the compositor to `ghostpen --trigger` instead (plan §10).
///
/// Returns `Err` with a user-readable message when the hotkey string is invalid or the OS
/// refuses the binding (e.g. the combo is already grabbed by another app). Callers surface
/// it: `save_settings` propagates it to the Settings UI; startup logs it.
fn register_hotkey(app: &AppHandle, hotkey: &str) -> Result<(), String> {
    let session = {
        let state = app.state::<AppState>();
        let pal = lock_recover(&state.pal);
        pal.session
    };
    if session.is_wayland() {
        return Ok(());
    }
    let gs = app.global_shortcut();
    // Clearing stale binds is best-effort: nothing registered yet is not an error.
    if let Err(e) = gs.unregister_all() {
        tracing::warn!("failed to clear existing global shortcuts: {e}");
    }
    let shortcut =
        parse_hotkey(hotkey).ok_or_else(|| format!("'{hotkey}' is not a valid hotkey"))?;
    let handle = app.clone();
    gs.on_shortcut(shortcut, move |_app, _sc, event| {
        if event.state() == ShortcutState::Pressed {
            trigger_menu_flow(&handle);
        }
    })
    .map_err(|e| format!("could not register hotkey '{hotkey}': {e}"))?;
    Ok(())
}

// ---- trigger flow --------------------------------------------------------------------

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.center();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

fn show_window(app: &AppHandle, label: &str) {
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Usage text for `--help`. Kept in one place so it stays in sync with the flags
/// `handle_cli_args` actually understands.
const HELP_TEXT: &str = "\
GhostPen — AI text editing overlay

Highlight text anywhere, trigger GhostPen, pick an action (proofread, rewrite,
concise, translate), and the result is pasted back in place.

USAGE:
    ghostpen [FLAGS]

FLAGS:
    --trigger       Show the action menu for the current selection. If GhostPen is
                        already running, this is forwarded to the running daemon (bind
                        this to a hotkey, e.g. Ctrl+Shift+A, in your compositor).
    --voice-input   Toggle voice dictation: start listening on the microphone, press
                        again to stop — the transcript is AI-proofread and copied to the
                        clipboard. Bind it in your compositor (e.g. Ctrl+Shift+D). Needs
                        a build with the captions feature (whisper).
    --captions      Toggle live captions: show the overlay and start captioning system
                        audio; run again to stop and hide it. Bind it in your compositor
                        (e.g. Ctrl+Shift+L). Needs a build with the captions feature.
    --settings      Open the Settings window.
    --playground    Open the Playground window.
    --tray          Run in system tray only, without showing the action menu. This
                        is the default behavior; the flag just makes it explicit (handy
                        in autostart entries / .desktop files).
    -h, --help      Print this help and exit.
    -V, --version   Print version and exit.

With no flags, GhostPen starts as a background daemon (system tray + global hotkey
on X11/Windows/macOS; on Wayland bind `ghostpen --trigger` in your compositor). The
menu stays hidden until you trigger it.

CONFIG:
    Settings live in the app's data dir (settings.json). The default AI backend is a
    local Ollama at http://localhost:11434 running the `gemma4:e4b` model.
";

/// Handle help/version, which must work without a display and without disturbing a
/// running daemon. Prints and exits the process when one of these flags is present;
/// returns normally otherwise so startup can continue.
fn handle_help_version(args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print!("{HELP_TEXT}");
        std::process::exit(0);
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("ghostpen {}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }
}

/// Handle CLI args (used at first launch and forwarded by single-instance):
/// `--trigger` shows the menu, `--voice-input` toggles dictation (ADR-009),
/// `--playground` / `--settings` open those windows.
/// `--tray` runs in background tray mode only (no menu).
fn handle_cli_args(app: &AppHandle, args: &[String]) {
    if args.iter().any(|a| a == "--trigger") {
        trigger_menu_flow(app);
    }
    if args.iter().any(|a| a == "--voice-input") {
        voice_input_toggle(app);
    }
    if args.iter().any(|a| a == "--captions") {
        captions_toggle(app);
    }
    if args.iter().any(|a| a == "--playground") {
        show_window(app, "playground");
    }
    if args.iter().any(|a| a == "--settings") {
        show_window(app, "settings");
    }
    // --tray: explicit form of the default — run in background tray mode only,
    // without showing the menu. The menu window starts hidden (tauri.conf.json
    // `visible: false`), so this is a no-op kept for clarity in autostart entries.
}

/// System-tray icon: Show menu / Playground / Settings / Quit, plus left-click to summon.
/// Returns Err if the platform can't create a tray (e.g. some Sommelier/Crostini setups);
/// the caller logs and continues so startup never fails on a missing tray.
fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Show menu", true, None::<&str>)?;
    let dictate = MenuItem::with_id(app, "dictate", "Dictation", true, None::<&str>)?;
    let captions = MenuItem::with_id(app, "captions", "Captions", true, None::<&str>)?;
    let playground = MenuItem::with_id(app, "playground", "Playground", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &dictate, &captions, &playground, &settings, &quit])?;

    TrayIconBuilder::with_id("ghostpen-tray")
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("GhostPen")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => trigger_menu_flow(app),
            "dictate" => voice_input_toggle(app),
            "captions" => open_captions(app.clone()),
            "playground" => show_window(app, "playground"),
            "settings" => show_window(app, "settings"),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                trigger_menu_flow(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

/// Entry point for every trigger (hotkey, `--trigger`, or the in-app "show" command).
/// Snapshots the original clipboard BEFORE synthetic copy (ADR-003); in manual mode it
/// leaves the clipboard untouched (the user has already copied the selection).
fn trigger_menu_flow(app: &AppHandle) {
    let settings = load_settings(app);
    let state = app.state::<AppState>();
    {
        let mut pal = lock_recover(&state.pal);
        if pal.use_synthetic(settings.force_synthetic) {
            let original = pal.clipboard.read_text().ok();
            *lock_recover(&state.saved_clipboard) = original;
            let _ = pal.input.copy();
        } else {
            *lock_recover(&state.saved_clipboard) = None;
        }
    }
    show_main(app);
    // Tell the overlay this is a fresh trigger: reset to the menu and re-read the selection.
    // (Distinguishes a real trigger from a mere window-focus event — see Menu.tsx.)
    let _ = app.emit("ghostpen://show", ());
}

// ---- action resolution ---------------------------------------------------------------

const BUILTIN_ACTIONS: &[&str] = &[
    "proofread",
    "professional",
    "casual",
    "concise",
    "expand",
    "translate",
];

/// Resolve an action id to its system prompt and an optional per-action model override.
/// Built-in actions use the strict prompts in `ai`; custom actions come from settings.
fn resolve_action(
    settings: &config::Settings,
    action: &str,
    target_lang: Option<&str>,
    level: Option<&str>,
) -> Result<(String, Option<String>), String> {
    if BUILTIN_ACTIONS.contains(&action) {
        Ok((ai::system_prompt(action, target_lang, level)?, None))
    } else if let Some(ca) = settings.custom_actions.iter().find(|a| a.id == action) {
        let model = if ca.model.trim().is_empty() {
            None
        } else {
            Some(ca.model.clone())
        };
        Ok((ca.prompt.clone(), model))
    } else {
        Err(format!("Unknown action: {action}"))
    }
}

// ---- commands ------------------------------------------------------------------------

#[tauri::command]
fn get_settings(app: AppHandle) -> config::Settings {
    load_settings(&app)
}

#[tauri::command]
fn save_settings(app: AppHandle, settings: config::Settings) -> Result<(), String> {
    persist_settings(&app, &settings)?;
    // Settings are already saved; if the hotkey can't be bound, tell the user why
    // (the Settings UI shows this) rather than failing silently.
    register_hotkey(&app, &settings.hotkey)
        .map_err(|e| format!("Settings saved, but the hotkey wasn't registered: {e}"))?;
    Ok(())
}

#[tauri::command]
async fn fetch_models(base_url: String, api_key: String) -> Result<Vec<String>, String> {
    ai::list_models(&base_url, &api_key).await
}

#[tauri::command]
fn get_status(app: AppHandle) -> Status {
    let settings = load_settings(&app);
    let state = app.state::<AppState>();
    let pal = lock_recover(&state.pal);
    let synthetic = pal.use_synthetic(settings.force_synthetic);
    let (profile, model) = settings
        .active()
        .map(|p| (p.name.clone(), p.model.clone()))
        .unwrap_or_else(|| ("(none)".into(), "(none)".into()));
    Status {
        session: pal.session.label().into(),
        clipboard_backend: pal.clipboard_backend_name().into(),
        input_available: pal.input.available(),
        use_synthetic: synthetic,
        manual_mode: !synthetic,
        active_profile: profile,
        active_model: model,
    }
}

#[tauri::command]
fn get_selection(app: AppHandle) -> Result<String, String> {
    let state = app.state::<AppState>();
    let mut pal = lock_recover(&state.pal);
    pal.clipboard.read_text().map_err(|e| e.to_string())
}

/// Try to mark the app busy; Err if a request is already in flight. Paired with `release_busy`.
fn try_acquire_busy(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let mut busy = lock_recover(&state.busy);
    if *busy {
        return Err("Already processing a request…".into());
    }
    *busy = true;
    Ok(())
}

fn release_busy(app: &AppHandle) {
    let state = app.state::<AppState>();
    *lock_recover(&state.busy) = false;
}

#[tauri::command]
async fn process_ai_action(
    app: AppHandle,
    action: String,
    target_lang: Option<String>,
    level: Option<String>,
) -> Result<ProcessResult, String> {
    try_acquire_busy(&app)?;
    let resolved = {
        let settings = load_settings(&app);
        resolve_action(&settings, &action, target_lang.as_deref(), level.as_deref())
    };
    let result = match resolved {
        Ok((system, model_override)) => process_inner(&app, &system, model_override).await,
        Err(e) => Err(e),
    };
    release_busy(&app);
    result
}

/// Freeform instruction typed in the menu's prompt bar, applied to the current selection and
/// pasted back exactly like a preset action (uses the active profile's model).
#[tauri::command]
async fn process_ai_custom(app: AppHandle, instruction: String) -> Result<ProcessResult, String> {
    if instruction.trim().is_empty() {
        return Err("No instruction provided".into());
    }
    try_acquire_busy(&app)?;
    let system = ai::custom_system_prompt(&instruction);
    let result = process_inner(&app, &system, None).await;
    release_busy(&app);
    result
}

async fn process_inner(
    app: &AppHandle,
    system: &str,
    model_override: Option<String>,
) -> Result<ProcessResult, String> {
    let settings = load_settings(app);
    let mut profile = settings
        .active()
        .ok_or("No active AI profile configured")?
        .clone();
    if let Some(m) = model_override {
        profile.model = m;
    }

    // Read the selection (the AI input). Never hold the PAL lock across an await.
    let selected = {
        let state = app.state::<AppState>();
        let mut pal = lock_recover(&state.pal);
        pal.clipboard.read_text().map_err(|e| e.to_string())?
    };
    if selected.trim().is_empty() {
        return Err("No text selected".into());
    }

    let output = ai::run_completion(&profile, system, &selected).await?;

    let synthetic = {
        let state = app.state::<AppState>();
        let pal = lock_recover(&state.pal);
        pal.use_synthetic(settings.force_synthetic)
    };

    // Put the result on the clipboard.
    {
        let state = app.state::<AppState>();
        let mut pal = lock_recover(&state.pal);
        pal.clipboard.write_text(&output).map_err(|e| e.to_string())?;
    }

    if synthetic {
        // Hide the overlay BEFORE pasting so the keystroke lands in the underlying app.
        if let Some(w) = app.get_webview_window("main") {
            let _ = w.hide();
        }
        {
            let state = app.state::<AppState>();
            let mut pal = lock_recover(&state.pal);
            let _ = pal.input.paste();
        }
        // Restore the user's original clipboard after the paste lands.
        let saved = {
            let state = app.state::<AppState>();
            let taken = lock_recover(&state.saved_clipboard).take();
            taken
        };
        if let Some(original) = saved {
            let app2 = app.clone();
            let delay = settings.restore_delay_ms;
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(delay));
                let state = app2.state::<AppState>();
                let mut pal = lock_recover(&state.pal);
                if let Err(e) = pal.clipboard.write_text(&original) {
                    tracing::warn!("failed to restore original clipboard: {e}");
                }
            });
        }
        Ok(ProcessResult {
            output,
            pasted: true,
            manual: false,
        })
    } else {
        // Manual mode: the result is on the clipboard for the user to paste themselves.
        Ok(ProcessResult {
            output,
            pasted: false,
            manual: true,
        })
    }
}

/// Playground: transform `text` directly and return the result. No clipboard, no paste —
/// for testing actions by typing/pasting into a textarea.
#[tauri::command]
async fn process_text(
    app: AppHandle,
    action: String,
    target_lang: Option<String>,
    level: Option<String>,
    text: String,
) -> Result<String, String> {
    if text.trim().is_empty() {
        return Err("No text provided".into());
    }
    let settings = load_settings(&app);
    let mut profile = settings
        .active()
        .ok_or("No active AI profile configured")?
        .clone();
    let (system, model_override) =
        resolve_action(&settings, &action, target_lang.as_deref(), level.as_deref())?;
    if let Some(m) = model_override {
        profile.model = m;
    }
    ai::run_completion(&profile, &system, &text).await
}

/// Streaming variant of `process_text`: emits `ghostpen://chunk` per delta, then
/// `ghostpen://done` (full text) or `ghostpen://error`. Used by the Playground live preview.
#[tauri::command]
async fn process_text_stream(
    app: AppHandle,
    window: tauri::Window,
    action: String,
    target_lang: Option<String>,
    level: Option<String>,
    text: String,
) -> Result<(), String> {
    if text.trim().is_empty() {
        return Err("No text provided".into());
    }
    let settings = load_settings(&app);
    let mut profile = settings
        .active()
        .ok_or("No active AI profile configured")?
        .clone();
    let (system, model_override) =
        resolve_action(&settings, &action, target_lang.as_deref(), level.as_deref())?;
    if let Some(m) = model_override {
        profile.model = m;
    }

    let emitter = window.clone();
    let result = ai::run_completion_stream(&profile, &system, &text, move |chunk| {
        let _ = emitter.emit("ghostpen://chunk", chunk);
    })
    .await;

    match result {
        Ok(full) => {
            let _ = window.emit("ghostpen://done", full);
            Ok(())
        }
        Err(e) => {
            let _ = window.emit("ghostpen://error", e.clone());
            Err(e)
        }
    }
}

#[tauri::command]
fn open_playground(app: AppHandle) {
    if let Some(w) = app.get_webview_window("playground") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[tauri::command]
fn show_menu(app: AppHandle) {
    trigger_menu_flow(&app);
}

#[tauri::command]
fn hide_window(window: tauri::WebviewWindow) {
    // Hide the window that invoked the command (the main overlay or the captions overlay),
    // not a hardcoded label — so each overlay's ✕ closes itself.
    let _ = window.hide();
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[tauri::command]
fn close_settings(app: AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.hide();
    }
}

// ---- captions commands (ADR-008) -----------------------------------------------------

/// Position the captions overlay along the bottom-center of its monitor, then show it.
/// (Tauri can't express a bottom-anchored window in tauri.conf.json, so we place it here.)
fn place_captions_bottom(w: &tauri::WebviewWindow) {
    if let Ok(Some(monitor)) = w.current_monitor() {
        let screen = monitor.size();
        let win = w.outer_size().unwrap_or(tauri::PhysicalSize::new(900, 160));
        let margin = (screen.height as f64 * 0.06) as i32; // ~6% up from the bottom edge
        let x = ((screen.width as i32 - win.width as i32) / 2).max(0);
        let y = (screen.height as i32 - win.height as i32 - margin).max(0);
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    }
}

#[tauri::command]
fn open_captions(app: AppHandle) {
    if let Some(w) = app.get_webview_window("captions") {
        // Showing the controls implies interactive: ensure click-through is off and tell the
        // overlay UI to leave ghost mode so the control bar reappears.
        let _ = w.set_ignore_cursor_events(false);
        place_captions_bottom(&w);
        let _ = w.show();
        let _ = w.set_focus();
        let _ = app.emit("ghostpen://captions-show", ());
    }
}

/// Toggle live captions — the `--captions` compositor keybind lands here. Not running →
/// show the overlay and start capturing; running → stop and hide. Start errors surface in
/// the overlay via `ghostpen://caption-error` (a keybind has no terminal to print to).
fn captions_toggle(app: &AppHandle) {
    let state = app.state::<AppState>();
    if state.captions.is_running() {
        state.captions.stop();
        if let Some(w) = app.get_webview_window("captions") {
            let _ = w.hide();
        }
        return;
    }
    open_captions(app.clone());
    let settings = load_settings(app);
    let started = {
        let state = app.state::<AppState>();
        state.captions.start(app, &settings)
    };
    match started {
        // Re-emit show so the overlay refreshes its status (Start → Stop) now that we run.
        Ok(_) => {
            let _ = app.emit("ghostpen://captions-show", ());
        }
        Err(e) => {
            let _ = app.emit("ghostpen://caption-error", e);
        }
    }
}

#[tauri::command]
fn captions_status(app: AppHandle) -> captions::CaptionsStatus {
    let settings = load_settings(&app);
    let state = app.state::<AppState>();
    state.captions.status(&settings)
}

#[tauri::command]
fn captions_list_devices() -> Vec<String> {
    #[cfg(feature = "captions")]
    {
        captions::audio::list_devices()
    }
    #[cfg(not(feature = "captions"))]
    {
        Vec::new()
    }
}

#[tauri::command]
fn captions_start(app: AppHandle) -> Result<String, String> {
    let settings = load_settings(&app);
    let device = {
        let state = app.state::<AppState>();
        state.captions.start(&app, &settings)?
    };
    // Bring the overlay up so the user sees captions appear.
    if let Some(w) = app.get_webview_window("captions") {
        place_captions_bottom(&w);
        let _ = w.show();
    }
    Ok(device)
}

#[tauri::command]
fn captions_stop(app: AppHandle) {
    let state = app.state::<AppState>();
    state.captions.stop();
}

/// Toggle the overlay's click-through (ghost) mode. When on, the mouse passes through the
/// window to whatever is underneath (the video/meeting), exactly like Netflix subtitles.
#[tauri::command]
fn captions_set_click_through(app: AppHandle, enable: bool) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("captions") {
        w.set_ignore_cursor_events(enable).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Toggle AI translation of captions from the overlay. Persists the choice to settings and,
/// if a session is running, flips it live so the next transcribed chunk is translated (or not)
/// without restarting capture.
#[tauri::command]
fn captions_set_translate(app: AppHandle, enable: bool) -> Result<(), String> {
    let mut settings = load_settings(&app);
    settings.captions.ai_translate = enable;
    persist_settings(&app, &settings)?;
    app.state::<AppState>().captions.set_translate(enable);
    Ok(())
}

/// Download the configured whisper model (or a specific one) to the app data dir.
#[tauri::command]
async fn captions_download_model(app: AppHandle, model: Option<String>) -> Result<(), String> {
    let model = match model {
        Some(m) if !m.trim().is_empty() => m,
        _ => load_settings(&app).captions.model,
    };
    captions::model::ensure_model(&model).await.map(|_| ())
}

// ---- dictation commands (ADR-009) ------------------------------------------------------

/// Toggle dictation — the `--voice-input` flag, the tray item, and the overlay all land here.
/// Not running → show the overlay and start listening; running → stop & finalize (the detached
/// worker transcribes, proofreads, and pastes). Errors (model missing, no captions build) are
/// emitted to the overlay so a keybind trigger still tells the user what's wrong.
fn voice_input_toggle(app: &AppHandle) {
    let state = app.state::<AppState>();
    if state.dictation.is_running() {
        state.dictation.stop();
        return;
    }
    show_dictation_overlay(app);
    let settings = load_settings(app);
    if let Err(e) = state.dictation.start(app, &settings) {
        let _ = app.emit(
            "ghostpen://dictation",
            dictation::DictationUpdate {
                text: e,
                state: "error".into(),
                pasted: false,
                manual: false,
            },
        );
    }
}

/// Position the dictation pill bottom-center (like captions) and show it focused, so
/// Esc/Enter work. `ghostpen://dictation-show` tells the overlay to reset for a new session.
fn show_dictation_overlay(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("dictation") {
        place_captions_bottom(&w);
        let _ = w.show();
        let _ = w.set_focus();
        // Compositor window rules can re-center the window as it (re)maps — the Hyprland setup
        // pins/centers all GhostPen windows — overriding the pre-show placement. Re-place now
        // and once more after mapping settles. (Captions dodges this only because Start
        // re-positions it while already visible.)
        place_captions_bottom(&w);
        let w2 = w.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(120));
            place_captions_bottom(&w2);
        });
    }
    let _ = app.emit("ghostpen://dictation-show", ());
}

/// Microphone candidates for the Settings picker (never `.monitor`/loopback sources).
#[tauri::command]
fn dictation_list_devices() -> Vec<String> {
    #[cfg(feature = "captions")]
    {
        captions::audio::list_input_devices()
    }
    #[cfg(not(feature = "captions"))]
    {
        Vec::new()
    }
}

#[tauri::command]
fn dictation_status(app: AppHandle) -> dictation::DictationStatus {
    let settings = load_settings(&app);
    let state = app.state::<AppState>();
    state.dictation.status(&settings)
}

/// Start listening (overlay button path). Resolves to the capture device name.
#[tauri::command]
fn dictation_start(app: AppHandle) -> Result<String, String> {
    let settings = load_settings(&app);
    let state = app.state::<AppState>();
    let device = state.dictation.start(&app, &settings)?;
    show_dictation_overlay(&app);
    Ok(device)
}

/// Stop listening and finalize (transcribe → proofread → paste). Returns immediately;
/// progress streams via `ghostpen://dictation` events.
#[tauri::command]
fn dictation_stop(app: AppHandle) {
    let state = app.state::<AppState>();
    state.dictation.stop();
}

/// Set the spoken language from the overlay's chip: persists to settings and flips the
/// live value so a running session uses it on its very next transcription pass.
#[tauri::command]
fn dictation_set_language(app: AppHandle, language: String) -> Result<(), String> {
    let mut settings = load_settings(&app);
    settings.dictation.language = language.clone();
    persist_settings(&app, &settings)?;
    app.state::<AppState>().dictation.set_language(&language);
    Ok(())
}

/// Cancel: discard the captured audio and hide the overlay.
#[tauri::command]
fn dictation_cancel(app: AppHandle) {
    let state = app.state::<AppState>();
    state.dictation.cancel();
    if let Some(w) = app.get_webview_window("dictation") {
        let _ = w.hide();
    }
}

// ---- entrypoint ----------------------------------------------------------------------

/// WebKitGTK's DMABUF renderer crashes with "Error 71 (Protocol error) dispatching to
/// Wayland display" on wlroots compositors (Hyprland, Sway). Disable it before GTK/webview
/// init. Only on Wayland, and only if the user hasn't set the variable themselves (so they
/// can opt back into the DMABUF renderer / keep hardware accel on X11). See ADR notes.
#[cfg(target_os = "linux")]
fn apply_wayland_webkit_workaround() {
    let on_wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let already_set = std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_some();
    if on_wayland && !already_set {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Handle --help / --version before any GUI/daemon setup so they work headless and
    // without forwarding into (or starting) the daemon.
    handle_help_version(&std::env::args().collect::<Vec<_>>());

    #[cfg(target_os = "linux")]
    apply_wayland_webkit_workaround();

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .init();

    tauri::Builder::default()
        // single-instance MUST be first: a second `ghostpen --trigger` launch forwards its
        // args into the running daemon instead of starting a new process.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            handle_cli_args(app, &argv);
        }))
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        // GhostPen is a tray-resident daemon: closing a window (e.g. the Settings titlebar ✕)
        // must HIDE it, not destroy it — otherwise `get_webview_window(...)` returns None and
        // the tray/`open_settings` can never reopen it. Quit still exits via the tray menu.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .manage(AppState::new())
        .setup(|app| {
            let handle = app.handle().clone();
            // Persist defaults on first run so the store always has a valid shape.
            let settings = load_settings(&handle);
            let _ = persist_settings(&handle, &settings);
            if let Err(e) = register_hotkey(&handle, &settings.hotkey) {
                tracing::warn!("global hotkey not registered: {e}");
            }
            if let Err(e) = build_tray(&handle) {
                tracing::warn!("system tray unavailable: {e}");
            }
            // The menu window starts hidden (tauri.conf.json `visible: false`), so a
            // bare launch (or `--tray`) stays in the background. Only an explicit
            // --trigger/--settings/--playground reveals a window at startup.
            let args: Vec<String> = std::env::args().collect();
            handle_cli_args(&handle, &args);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            save_settings,
            fetch_models,
            get_status,
            get_selection,
            process_ai_action,
            process_ai_custom,
            process_text,
            process_text_stream,
            show_menu,
            hide_window,
            open_settings,
            open_playground,
            close_settings,
            open_captions,
            captions_status,
            captions_list_devices,
            captions_start,
            captions_stop,
            captions_set_click_through,
            captions_set_translate,
            captions_download_model,
            dictation_list_devices,
            dictation_status,
            dictation_start,
            dictation_stop,
            dictation_cancel,
            dictation_set_language
        ])
        .run(tauri::generate_context!())
        .expect("error while running GhostPen");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotkey_parses_default() {
        assert!(parse_hotkey("Ctrl+Shift+A").is_some());
        assert!(parse_hotkey("Ctrl+Shift+Space").is_some());
    }

    #[test]
    fn hotkey_parses_letter_and_case_insensitive() {
        assert!(parse_hotkey("ctrl+alt+K").is_some());
        assert!(parse_hotkey("Super+1").is_some());
    }

    #[test]
    fn hotkey_without_keycode_is_none() {
        assert!(parse_hotkey("Ctrl+Shift").is_none());
    }

    #[test]
    fn system_prompt_translate_includes_language() {
        let p = ai::system_prompt("translate", Some("Spanish"), None).unwrap();
        assert!(p.contains("Spanish"));
    }

    #[test]
    fn system_prompt_rejects_unknown_action() {
        assert!(ai::system_prompt("nope", None, None).is_err());
    }

    #[test]
    fn system_prompt_level_changes_professional() {
        let subtle = ai::system_prompt("professional", None, Some("subtle")).unwrap();
        let strong = ai::system_prompt("professional", None, Some("strong")).unwrap();
        let balanced = ai::system_prompt("professional", None, None).unwrap();
        assert_ne!(subtle, strong);
        assert_ne!(subtle, balanced);
        assert!(strong.to_lowercase().contains("formal"));
    }

    #[test]
    fn system_prompt_level_ignored_for_proofread() {
        let a = ai::system_prompt("proofread", None, Some("subtle")).unwrap();
        let b = ai::system_prompt("proofread", None, Some("strong")).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn settings_defaults_are_valid() {
        let s = config::Settings::defaults();
        let active = s.active().expect("default has an active profile");
        assert_eq!(active.model, "gemma4:e4b");
        assert_eq!(active.base_url, "http://localhost:11434/v1");
    }

    #[test]
    fn settings_roundtrip_serde() {
        let s = config::Settings::defaults();
        let json = serde_json::to_string(&s).unwrap();
        // Camel-case rename is applied for the frontend.
        assert!(json.contains("activeProfileId"));
        assert!(json.contains("baseUrl"));
        let back: config::Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.active_profile_id, s.active_profile_id);
    }

    #[test]
    fn session_detect_runs() {
        let _ = pal::detect_session();
    }
}
