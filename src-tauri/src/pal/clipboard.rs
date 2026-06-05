//! Clipboard backends (ADR-002, revisited).
//!
//! - `ArboardClipboard` — X11, macOS, Windows. A fresh handle per call (ZST, trivially `Send`).
//! - `WaylandClipboard` — native Wayland via `wl-clipboard-rs`. On a Wayland session arboard
//!   only talks to the X11 clipboard through XWayland, and writes are lost across the
//!   X11↔Wayland bridge (and when the per-call handle drops). The Wayland clipboard is a live
//!   *offer* from a source client, so a write must keep serving — we do that from a detached
//!   thread that lives until another app takes the selection.

use super::{ClipboardBackend, PalError};

#[derive(Default)]
pub struct ArboardClipboard;

impl ClipboardBackend for ArboardClipboard {
    fn read_text(&mut self) -> Result<String, PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        match cb.get_text() {
            Ok(s) => Ok(s),
            // An empty / non-text clipboard is not an error — treat as empty string.
            Err(arboard::Error::ContentNotAvailable) => Ok(String::new()),
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_text(&mut self, text: &str) -> Result<(), PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        cb.set_text(text.to_string())
            .map_err(|e| PalError::Clipboard(e.to_string()))
    }
}

#[cfg(target_os = "linux")]
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};

#[cfg(target_os = "linux")]
#[derive(Default)]
pub struct WaylandClipboard {
    /// The value we last wrote and are currently serving (valid while `owned` is true).
    last_written: Arc<Mutex<String>>,
    /// True while our serve thread still holds the selection (no other app has copied since).
    owned: Arc<AtomicBool>,
    /// Bumped on every write so a superseded serve thread can't clear `owned` for a newer write.
    generation: Arc<AtomicU64>,
}

#[cfg(target_os = "linux")]
impl ClipboardBackend for WaylandClipboard {
    fn read_text(&mut self) -> Result<String, PalError> {
        // If we still own the selection, reading it back over Wayland means this process serving
        // AND consuming its own offer — which can deadlock and freeze the (main-thread) UI. The
        // value we're serving IS the current selection until another app copies, so return it.
        if self.owned.load(Ordering::Acquire) {
            return Ok(self.last_written.lock().unwrap().clone());
        }

        use std::io::Read;
        use wl_clipboard_rs::paste::{get_contents, ClipboardType, Error, MimeType, Seat};

        match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Text) {
            Ok((mut pipe, _mime)) => {
                let mut buf = Vec::new();
                pipe.read_to_end(&mut buf)
                    .map_err(|e| PalError::Clipboard(e.to_string()))?;
                Ok(String::from_utf8_lossy(&buf).into_owned())
            }
            // Nothing (text) on the clipboard is not an error — treat as empty.
            Err(Error::NoSeats) | Err(Error::ClipboardEmpty) | Err(Error::NoMimeType) => {
                Ok(String::new())
            }
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_text(&mut self, text: &str) -> Result<(), PalError> {
        use wl_clipboard_rs::copy::{MimeType, Options, ServeRequests, Source};

        // Mark ourselves the owner before serving so an immediate read returns the cached value.
        let my_gen = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        *self.last_written.lock().unwrap() = text.to_string();
        self.owned.store(true, Ordering::Release);

        let bytes = text.as_bytes().to_vec().into_boxed_slice();
        let owned = Arc::clone(&self.owned);
        let generation = Arc::clone(&self.generation);
        // Serve the selection from a detached thread. `foreground(true)` serves in THIS thread
        // (no fork() — unsafe in our multithreaded process); `Unlimited` answers any number of
        // pastes. `copy` blocks until another app copies (or errors), then returns.
        std::thread::Builder::new()
            .name("ghostpen-clipboard".into())
            .spawn(move || {
                let mut opts = Options::new();
                opts.foreground(true);
                opts.serve_requests(ServeRequests::Unlimited);
                if let Err(e) = opts.copy(Source::Bytes(bytes), MimeType::Text) {
                    tracing::warn!("wayland clipboard serve failed: {e}");
                }
                // Serve ended (selection lost or error). Relinquish ownership only if a newer
                // write hasn't taken over since — otherwise we'd clear the newer owner's flag.
                if generation.load(Ordering::Acquire) == my_gen {
                    owned.store(false, Ordering::Release);
                }
            })
            .map_err(|e| PalError::Clipboard(e.to_string()))?;
        Ok(())
    }
}
