//! Clipboard backend — arboard on all platforms (ADR-002).
//!
//! Validated on Crostini (spike 0.1) incl. cross-boundary reads. A fresh `arboard::Clipboard`
//! is created per call so the backend type stays a ZST and is trivially `Send`.

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
