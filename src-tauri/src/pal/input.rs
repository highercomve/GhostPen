//! Input-synthesis backend — enigo 0.6 (ADR-005).
//!
//! Never panics: `Enigo` is created fallibly per call and every key event returns `Result`.
//! Availability is probed once at construction; if enigo can't initialise, the app runs in
//! manual-copy mode.

use super::{InputBackend, PalError};
use enigo::{Direction, Enigo, Key, Keyboard, Settings};
use std::thread;
use std::time::Duration;

pub struct EnigoInput {
    available: bool,
}

impl EnigoInput {
    pub fn new() -> Self {
        // Probe once — if we can't even construct an Enigo, synthetic input is unavailable.
        let available = Enigo::new(&Settings::default()).is_ok();
        EnigoInput { available }
    }

    fn modifier() -> Key {
        if cfg!(target_os = "macos") {
            Key::Meta
        } else {
            Key::Control
        }
    }

    fn chord(&self, letter: char) -> Result<(), PalError> {
        let mut enigo =
            Enigo::new(&Settings::default()).map_err(|e| PalError::Input(e.to_string()))?;
        let m = Self::modifier();
        enigo
            .key(m, Direction::Press)
            .map_err(|e| PalError::Input(e.to_string()))?;
        enigo
            .key(Key::Unicode(letter), Direction::Click)
            .map_err(|e| PalError::Input(e.to_string()))?;
        enigo
            .key(m, Direction::Release)
            .map_err(|e| PalError::Input(e.to_string()))?;
        Ok(())
    }
}

impl InputBackend for EnigoInput {
    fn copy(&mut self) -> Result<(), PalError> {
        self.chord('c')?;
        // Give the source app a moment to populate the clipboard.
        thread::sleep(Duration::from_millis(80));
        Ok(())
    }

    fn paste(&mut self) -> Result<(), PalError> {
        self.chord('v')
    }

    fn available(&self) -> bool {
        self.available
    }
}
