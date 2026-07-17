//! Image helpers for the OCR / image-text-extraction feature (ADR-011).
//!
//! Encoding, resizing, and base64 are isolated here so they can be unit-tested without
//! touching the clipboard or the WebView. No raw image bytes cross into the frontend.

use base64::{engine::general_purpose, Engine as _};
use image::{DynamicImage, GenericImageView, ImageFormat};

/// Encode raw RGBA pixels into a PNG.
pub fn rgba_to_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let img = DynamicImage::ImageRgba8(
        image::RgbaImage::from_raw(width, height, rgba.to_vec())
            .ok_or_else(|| "invalid RGBA dimensions".to_string())?,
    );
    let mut buf = std::io::Cursor::new(Vec::new());
    img.write_to(&mut buf, ImageFormat::Png)
        .map_err(|e| format!("PNG encode failed: {e}"))?;
    Ok(buf.into_inner())
}

/// Resize a PNG so neither dimension exceeds `max`, preserving aspect ratio.
/// Uses Lanczos3 resampling so downscaled screenshots stay legible for OCR (ADR-011).
/// If the image is already within bounds, the original bytes are returned unchanged.
pub fn resize_to_max_dimension(png: &[u8], max: u32) -> Result<Vec<u8>, String> {
    // Guard against a zero or nonsensical max dimension without widening the unit-test range.
    let max = max.max(1);
    let img = image::load_from_memory(png)
        .map_err(|e| format!("PNG decode failed: {e}"))?;
    let (width, height) = img.dimensions();
    if width <= max && height <= max {
        return Ok(png.to_vec());
    }
    let resized = img.resize(max, max, image::imageops::FilterType::Lanczos3);
    let mut buf = std::io::Cursor::new(Vec::new());
    resized.write_to(&mut buf, ImageFormat::Png)
        .map_err(|e| format!("PNG encode failed: {e}"))?;
    Ok(buf.into_inner())
}

/// Fast, low-quality resize for the frontend preview.
/// Uses nearest-neighbor/box thumbnail filtering; quality is unimportant at 512 px preview size.
pub fn thumbnail_to_max_dimension(png: &[u8], max: u32) -> Result<Vec<u8>, String> {
    let max = max.max(1);
    let img = image::load_from_memory(png)
        .map_err(|e| format!("PNG decode failed: {e}"))?;
    let (width, height) = img.dimensions();
    if width <= max && height <= max {
        return Ok(png.to_vec());
    }
    let thumb = img.thumbnail(max, max);
    let mut buf = std::io::Cursor::new(Vec::new());
    thumb.write_to(&mut buf, ImageFormat::Png)
        .map_err(|e| format!("PNG encode failed: {e}"))?;
    Ok(buf.into_inner())
}

/// Decode PNG dimensions without loading the full image.
pub fn png_dimensions(png: &[u8]) -> Result<(u32, u32), String> {
    let reader = image::ImageReader::new(std::io::Cursor::new(png))
        .with_guessed_format()
        .map_err(|e| format!("PNG reader failed: {e}"))?;
    reader.into_dimensions()
        .map_err(|e| format!("PNG dimensions failed: {e}"))
}

/// Build a complete data-URI from PNG bytes. This is the ONLY place the `data:image/png;base64,`
/// prefix is constructed, so callers can pass the result straight to vision models.
pub fn to_data_uri(png: &[u8]) -> String {
    let b64 = general_purpose::STANDARD.encode(png);
    format!("data:image/png;base64,{b64}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgba_to_png_round_trip() {
        let rgba = vec![255u8, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255];
        let png = rgba_to_png(&rgba, 2, 2).unwrap();
        assert!(!png.is_empty());
        assert!(png.starts_with(b"\x89PNG"));
    }

    #[test]
    fn resize_to_max_dimension_downscales_large() {
        let rgba = vec![128u8; 64 * 64 * 4];
        let png = rgba_to_png(&rgba, 64, 64).unwrap();
        let resized = resize_to_max_dimension(&png, 32).unwrap();
        let (w, h) = png_dimensions(&resized).unwrap();
        assert!(w <= 32 && h <= 32);
    }

    #[test]
    fn resize_to_max_dimension_no_ops_small() {
        let rgba = vec![128u8; 32 * 32 * 4];
        let png = rgba_to_png(&rgba, 32, 32).unwrap();
        let resized = resize_to_max_dimension(&png, 64).unwrap();
        let (w, h) = png_dimensions(&resized).unwrap();
        assert_eq!((w, h), (32, 32));
    }

    #[test]
    fn resize_preserves_aspect_ratio() {
        let rgba = vec![128u8; 200 * 100 * 4];
        let png = rgba_to_png(&rgba, 200, 100).unwrap();
        let resized = resize_to_max_dimension(&png, 50).unwrap();
        let (w, h) = png_dimensions(&resized).unwrap();
        assert_eq!(w, 50);
        assert_eq!(h, 25);
    }

    #[test]
    fn to_data_uri_has_single_prefix() {
        let png = b"\x89PNG\r\n\x1a\n";
        let uri = to_data_uri(png);
        assert!(uri.starts_with("data:image/png;base64,"));
        assert_eq!(uri.matches("data:image/png;base64,").count(), 1);
    }

    #[test]
    fn png_dimensions_match_source() {
        let rgba = vec![128u8; 48 * 32 * 4];
        let png = rgba_to_png(&rgba, 48, 32).unwrap();
        assert_eq!(png_dimensions(&png).unwrap(), (48, 32));
    }
}
