//! Platform Abstraction Layer (PAL) — ADR-001.
//!
//! All OS interaction (clipboard, input synthesis) goes through these traits. The concrete
//! backend is chosen at runtime from `detect_session()`, never by compile-time `cfg!` alone,
//! because a single Linux binary runs on both X11 and Wayland.

use std::fmt;

pub mod clipboard;
pub mod input;

/// The runtime display/session GhostPen is running under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Session {
    Windows,
    MacOS,
    LinuxX11,
    LinuxWayland,
}

impl Session {
    pub fn label(self) -> &'static str {
        match self {
            Session::Windows => "Windows",
            Session::MacOS => "macOS",
            Session::LinuxX11 => "Linux/X11",
            Session::LinuxWayland => "Linux/Wayland",
        }
    }

    pub fn is_wayland(self) -> bool {
        matches!(self, Session::LinuxWayland)
    }
}

/// Runtime session probe. `cfg!` separates OS *families*; env vars separate X11 vs Wayland.
pub fn detect_session() -> Session {
    #[cfg(target_os = "windows")]
    {
        return Session::Windows;
    }
    #[cfg(target_os = "macos")]
    {
        return Session::MacOS;
    }
    #[cfg(target_os = "linux")]
    {
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some()
            || matches!(std::env::var("XDG_SESSION_TYPE").as_deref(), Ok("wayland"));
        return if wayland {
            Session::LinuxWayland
        } else {
            Session::LinuxX11
        };
    }
    #[allow(unreachable_code)]
    {
        Session::LinuxX11
    }
}

/// Errors surfaced from OS interaction. Never panic on an OS call (ADR-005).
#[derive(Debug)]
pub enum PalError {
    Clipboard(String),
    Input(String),
}

impl fmt::Display for PalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PalError::Clipboard(m) => write!(f, "clipboard error: {m}"),
            PalError::Input(m) => write!(f, "input error: {m}"),
        }
    }
}

impl std::error::Error for PalError {}

/// Clipboard read/write. Implementations create OS handles per call so the backend stays
/// `Send` (no long-lived non-Send OS connection held in shared state).
pub trait ClipboardBackend: Send {
    fn read_text(&mut self) -> Result<String, PalError>;
    fn write_text(&mut self, text: &str) -> Result<(), PalError>;
}

/// Synthetic keyboard input (Ctrl/Cmd+C / +V).
pub trait InputBackend: Send {
    fn copy(&mut self) -> Result<(), PalError>;
    fn paste(&mut self) -> Result<(), PalError>;
    /// Whether synthetic input can be created at all (e.g. enigo initialised).
    fn available(&self) -> bool;
}

/// The assembled platform layer stored in Tauri state.
pub struct Pal {
    pub session: Session,
    pub clipboard: Box<dyn ClipboardBackend>,
    pub input: Box<dyn InputBackend>,
}

impl Pal {
    pub fn detect() -> Self {
        let session = detect_session();
        Pal {
            session,
            clipboard: Box::new(clipboard::ArboardClipboard::default()),
            input: Box::new(input::EnigoInput::new()),
        }
    }

    /// Whether the app should drive the copy/paste itself (true) or run in manual-copy mode
    /// (false). On Wayland we default to manual unless explicitly forced (ADR-005/007),
    /// because libei-into-host is unreliable (and impossible under Crostini).
    pub fn use_synthetic(&self, force_synthetic: bool) -> bool {
        if !self.input.available() {
            return false;
        }
        if self.session.is_wayland() {
            force_synthetic
        } else {
            true
        }
    }
}
