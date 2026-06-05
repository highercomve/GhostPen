// GhostPen — backend entrypoint.
//
// Wires the Platform Abstraction Layer, the OpenAI-compatible AI client, the configurable
// settings, and the trigger/clipboard flow. See .agents/architecture.md for the ADRs that
// govern this code (PAL, snapshot-before-copy, no-panic OS calls, bounded HTTP, manual mode).

pub mod ai;
pub mod config;
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
}

impl AppState {
    fn new() -> Self {
        AppState {
            pal: Mutex::new(Pal::detect()),
            saved_clipboard: Mutex::new(None),
            busy: Mutex::new(false),
        }
    }
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

/// Register the in-process global hotkey (Windows/macOS/X11). On Wayland this is a no-op —
/// bind the key in the compositor to `ghostpen --trigger` instead (plan §10).
fn register_hotkey(app: &AppHandle, hotkey: &str) {
    let session = {
        let state = app.state::<AppState>();
        let pal = state.pal.lock().unwrap();
        pal.session
    };
    if session.is_wayland() {
        return;
    }
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    if let Some(shortcut) = parse_hotkey(hotkey) {
        let handle = app.clone();
        let _ = gs.on_shortcut(shortcut, move |_app, _sc, event| {
            if event.state() == ShortcutState::Pressed {
                trigger_menu_flow(&handle);
            }
        });
    }
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

/// Handle CLI args (used at first launch and forwarded by single-instance):
/// `--trigger` shows the menu, `--playground` / `--settings` open those windows.
fn handle_cli_args(app: &AppHandle, args: &[String]) {
    if args.iter().any(|a| a == "--trigger") {
        trigger_menu_flow(app);
    }
    if args.iter().any(|a| a == "--playground") {
        show_window(app, "playground");
    }
    if args.iter().any(|a| a == "--settings") {
        show_window(app, "settings");
    }
}

/// System-tray icon: Show menu / Playground / Settings / Quit, plus left-click to summon.
/// Returns Err if the platform can't create a tray (e.g. some Sommelier/Crostini setups);
/// the caller logs and continues so startup never fails on a missing tray.
fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Show menu", true, None::<&str>)?;
    let playground = MenuItem::with_id(app, "playground", "Playground", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &playground, &settings, &quit])?;

    TrayIconBuilder::with_id("ghostpen-tray")
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("GhostPen")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => trigger_menu_flow(app),
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
        let mut pal = state.pal.lock().unwrap();
        if pal.use_synthetic(settings.force_synthetic) {
            let original = pal.clipboard.read_text().ok();
            *state.saved_clipboard.lock().unwrap() = original;
            let _ = pal.input.copy();
        } else {
            *state.saved_clipboard.lock().unwrap() = None;
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
    register_hotkey(&app, &settings.hotkey);
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
    let pal = state.pal.lock().unwrap();
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
    let mut pal = state.pal.lock().unwrap();
    pal.clipboard.read_text().map_err(|e| e.to_string())
}

#[tauri::command]
async fn process_ai_action(
    app: AppHandle,
    action: String,
    target_lang: Option<String>,
    level: Option<String>,
) -> Result<ProcessResult, String> {
    // in-flight guard
    {
        let state = app.state::<AppState>();
        let mut busy = state.busy.lock().unwrap();
        if *busy {
            return Err("Already processing a request…".into());
        }
        *busy = true;
    }
    let result = process_inner(&app, &action, target_lang.as_deref(), level.as_deref()).await;
    {
        let state = app.state::<AppState>();
        *state.busy.lock().unwrap() = false;
    }
    result
}

async fn process_inner(
    app: &AppHandle,
    action: &str,
    target_lang: Option<&str>,
    level: Option<&str>,
) -> Result<ProcessResult, String> {
    let settings = load_settings(app);
    let mut profile = settings
        .active()
        .ok_or("No active AI profile configured")?
        .clone();
    let (system, model_override) = resolve_action(&settings, action, target_lang, level)?;
    if let Some(m) = model_override {
        profile.model = m;
    }

    // Read the selection (the AI input). Never hold the PAL lock across an await.
    let selected = {
        let state = app.state::<AppState>();
        let mut pal = state.pal.lock().unwrap();
        pal.clipboard.read_text().map_err(|e| e.to_string())?
    };
    if selected.trim().is_empty() {
        return Err("No text selected".into());
    }

    let output = ai::run_completion(&profile, &system, &selected).await?;

    let synthetic = {
        let state = app.state::<AppState>();
        let pal = state.pal.lock().unwrap();
        pal.use_synthetic(settings.force_synthetic)
    };

    // Put the result on the clipboard.
    {
        let state = app.state::<AppState>();
        let mut pal = state.pal.lock().unwrap();
        pal.clipboard.write_text(&output).map_err(|e| e.to_string())?;
    }

    if synthetic {
        // Hide the overlay BEFORE pasting so the keystroke lands in the underlying app.
        if let Some(w) = app.get_webview_window("main") {
            let _ = w.hide();
        }
        {
            let state = app.state::<AppState>();
            let mut pal = state.pal.lock().unwrap();
            let _ = pal.input.paste();
        }
        // Restore the user's original clipboard after the paste lands.
        let saved = {
            let state = app.state::<AppState>();
            let taken = state.saved_clipboard.lock().unwrap().take();
            taken
        };
        if let Some(original) = saved {
            let app2 = app.clone();
            let delay = settings.restore_delay_ms;
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(delay));
                let state = app2.state::<AppState>();
                let mut pal = match state.pal.lock() {
                    Ok(guard) => guard,
                    Err(_) => return,
                };
                let _ = pal.clipboard.write_text(&original);
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
fn hide_window(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.hide();
    }
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
        .manage(AppState::new())
        .setup(|app| {
            let handle = app.handle().clone();
            // Persist defaults on first run so the store always has a valid shape.
            let settings = load_settings(&handle);
            let _ = persist_settings(&handle, &settings);
            register_hotkey(&handle, &settings.hotkey);
            if let Err(e) = build_tray(&handle) {
                tracing::warn!("system tray unavailable: {e}");
            }
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
            process_text,
            process_text_stream,
            show_menu,
            hide_window,
            open_settings,
            open_playground,
            close_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running GhostPen");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotkey_parses_default() {
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
