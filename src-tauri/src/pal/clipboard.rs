//! Clipboard backends (ADR-002, revisited).
//!
//! - `ArboardClipboard` — X11, macOS, Windows. A fresh handle per call (ZST, trivially `Send`).
//! - `WaylandClipboard` — native Wayland via `wl-clipboard-rs`. On a Wayland session arboard
//!   only talks to the X11 clipboard through XWayland, and writes are lost across the
//!   X11↔Wayland bridge (and when the per-call handle drops). The Wayland clipboard is a live
//!   *offer* from a source client, so a write must keep serving — we do that from a detached
//!   thread that lives until another app takes the selection.

use super::{ClipboardBackend, ClipboardImage, PalError};
use std::io::Read;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};

#[cfg(target_os = "linux")]
use wl_clipboard_rs::copy::{MimeType as CopyMimeType, Options, ServeRequests, Source};
#[cfg(target_os = "linux")]
use wl_clipboard_rs::paste::{get_contents, ClipboardType, Error, MimeType, Seat};

#[cfg(target_os = "linux")]
#[derive(Default)]
pub struct WaylandClipData {
    pub text: Option<String>,
    pub image: Option<ClipboardImage>,
}

#[cfg(target_os = "linux")]
#[derive(Default)]
pub struct WaylandClipboard {
    /// The value we last wrote and are currently serving (valid while `owned` is true).
    last_written: Arc<Mutex<WaylandClipData>>,
    /// True while our serve thread still holds the selection (no other app has copied since).
    owned: Arc<AtomicBool>,
    /// Bumped on every write so a superseded serve thread can't clear `owned` for a newer write.
    generation: Arc<AtomicU64>,
}

#[derive(Default)]
pub struct ArboardClipboard;

impl ClipboardBackend for ArboardClipboard {
    fn read_text(&mut self) -> Result<String, PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        match cb.get_text() {
            Ok(s) => Ok(s),
            Err(arboard::Error::ContentNotAvailable) => Ok(String::new()),
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_text(&mut self, text: &str) -> Result<(), PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        cb.set_text(text.to_string())
            .map_err(|e| PalError::Clipboard(e.to_string()))
    }

    fn read_image(&mut self) -> Result<Option<ClipboardImage>, PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        match cb.get_image() {
            Ok(img) => {
                // arboard returns RGBA with the image crate's ImageData layout.
                let bytes = rgba_to_png_bytes(&img.bytes, img.width as u32, img.height as u32)?;
                Ok(Some(ClipboardImage {
                    mime: "image/png".to_string(),
                    bytes,
                }))
            }
            Err(arboard::Error::ContentNotAvailable) => Ok(None),
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_image(&mut self, image: &ClipboardImage) -> Result<(), PalError> {
        let mut cb = arboard::Clipboard::new().map_err(|e| PalError::Clipboard(e.to_string()))?;
        let rgba = png_to_rgba(&image.bytes)?;
        cb.set_image(arboard::ImageData {
            width: rgba.width as usize,
            height: rgba.height as usize,
            bytes: rgba.bytes.into(),
        })
        .map_err(|e| PalError::Clipboard(e.to_string()))
    }
}

/// Decode PNG to RGBA bytes for arboard.
fn png_to_rgba(png: &[u8]) -> Result<RgbaBuffer, PalError> {
    let img = image::load_from_memory(png)
        .map_err(|e| PalError::Clipboard(format!("decode PNG: {e}")))?;
    let img = img.to_rgba8();
    let (width, height) = img.dimensions();
    Ok(RgbaBuffer {
        width,
        height,
        bytes: img.into_raw(),
    })
}

/// Encode RGBA bytes to PNG.
fn rgba_to_png_bytes(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, PalError> {
    crate::image_util::rgba_to_png(rgba, width, height)
        .map_err(|e| PalError::Clipboard(format!("encode PNG: {e}")))
}

struct RgbaBuffer {
    width: u32,
    height: u32,
    bytes: Vec<u8>,
}

#[cfg(target_os = "linux")]
impl ClipboardBackend for WaylandClipboard {
    fn read_text(&mut self) -> Result<String, PalError> {
        if self.owned.load(Ordering::Acquire) {
            return Ok(self
                .last_written
                .lock()
                .unwrap()
                .text
                .clone()
                .unwrap_or_default());
        }

        match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Text) {
            Ok((mut pipe, _mime)) => {
                let mut buf = Vec::new();
                pipe.read_to_end(&mut buf)
                    .map_err(|e| PalError::Clipboard(e.to_string()))?;
                Ok(String::from_utf8_lossy(&buf).into_owned())
            }
            Err(Error::NoSeats) | Err(Error::ClipboardEmpty) | Err(Error::NoMimeType) => {
                Ok(String::new())
            }
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_text(&mut self, text: &str) -> Result<(), PalError> {
        let my_gen = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        {
            let mut data = self.last_written.lock().unwrap();
            data.text = Some(text.to_string());
            data.image = None;
        }
        self.owned.store(true, Ordering::Release);

        let bytes = text.as_bytes().to_vec().into_boxed_slice();
        let owned = Arc::clone(&self.owned);
        let generation = Arc::clone(&self.generation);
        std::thread::Builder::new()
            .name("ghostpen-clipboard".into())
            .spawn(move || {
                let mut opts = Options::new();
                opts.foreground(true);
                opts.serve_requests(ServeRequests::Unlimited);
                if let Err(e) = opts.copy(Source::Bytes(bytes), CopyMimeType::Text) {
                    tracing::warn!("wayland clipboard serve failed: {e}");
                }
                if generation.load(Ordering::Acquire) == my_gen {
                    owned.store(false, Ordering::Release);
                }
            })
            .map_err(|e| PalError::Clipboard(e.to_string()))?;
        Ok(())
    }

    fn read_image(&mut self) -> Result<Option<ClipboardImage>, PalError> {
        if self.owned.load(Ordering::Acquire) {
            let data = self.last_written.lock().unwrap();
            return Ok(data.image.clone());
        }

        match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Specific("image/png")) {
            Ok((mut pipe, _mime)) => {
                let mut buf = Vec::new();
                pipe.read_to_end(&mut buf)
                    .map_err(|e| PalError::Clipboard(e.to_string()))?;
                Ok(Some(ClipboardImage {
                    mime: "image/png".to_string(),
                    bytes: buf,
                }))
            }
            Err(Error::NoSeats) | Err(Error::ClipboardEmpty) => Ok(None),
            Err(Error::NoMimeType) => {
                // v1 is PNG-only. If the offer is image/jpeg, log a clear hint so the user
                // knows why the menu shows "no image" instead of silently discarding it.
                if matches!(
                    get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Specific("image/jpeg")),
                    Ok(_)
                ) {
                    tracing::warn!("clipboard contains image/jpeg, but Wayland v1 only supports image/png");
                }
                Ok(None)
            }
            Err(e) => Err(PalError::Clipboard(e.to_string())),
        }
    }

    fn write_image(&mut self, image: &ClipboardImage) -> Result<(), PalError> {
        let my_gen = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        {
            let mut data = self.last_written.lock().unwrap();
            data.text = None;
            data.image = Some(image.clone());
        }
        self.owned.store(true, Ordering::Release);

        let bytes = image.bytes.clone().into_boxed_slice();
        let owned = Arc::clone(&self.owned);
        let generation = Arc::clone(&self.generation);
        std::thread::Builder::new()
            .name("ghostpen-clipboard".into())
            .spawn(move || {
                let mut opts = Options::new();
                opts.foreground(true);
                opts.serve_requests(ServeRequests::Unlimited);
                if let Err(e) = opts.copy(Source::Bytes(bytes), CopyMimeType::Specific("image/png".to_string())) {
                    tracing::warn!("wayland clipboard serve failed: {e}");
                }
                if generation.load(Ordering::Acquire) == my_gen {
                    owned.store(false, Ordering::Release);
                }
            })
            .map_err(|e| PalError::Clipboard(e.to_string()))?;
        Ok(())
    }
}
