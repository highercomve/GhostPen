//! System-audio loopback capture (ADR-008), feature-gated behind `captions`.
//!
//! Captures the audio *leaving* the speakers (a meeting, a video, a podcast) rather than the
//! microphone, downmixes to mono, and resamples to the 16 kHz Whisper expects. The captured
//! samples accumulate in a shared buffer the transcription worker drains.
//!
//! Per the Critical rules, nothing here panics on an OS call: device/stream errors are
//! surfaced as `Err(String)` and the caller degrades gracefully.
//!
//! Loopback per OS (the hard part — see ADR-008):
//! - **Windows:** WASAPI loopback — build an *input* stream on the default *output* device.
//! - **Linux:** capture a PipeWire/PulseAudio **monitor** source (an input device whose name
//!   contains "monitor"); fall back to the default input device.
//! - **macOS:** Apple blocks direct system-audio capture; the user installs a virtual device
//!   (e.g. BlackHole) which appears as an input device — selected by name in settings.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleFormat, StreamConfig, SupportedStreamConfig};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Whisper wants 16 kHz mono f32.
pub const TARGET_RATE: u32 = 16_000;

/// A growable, capped accumulator the capture callback writes mono 16 kHz samples into and the
/// transcription worker drains. Capped so a stalled worker can't grow it without bound.
#[derive(Clone, Default)]
pub struct SampleBuffer {
    inner: Arc<Mutex<Vec<f32>>>,
}

impl SampleBuffer {
    /// ~60 s of 16 kHz mono audio — far more than any chunk; guards against unbounded growth.
    const MAX_SAMPLES: usize = TARGET_RATE as usize * 60;

    pub fn push(&self, samples: &[f32]) {
        if let Ok(mut buf) = self.inner.lock() {
            buf.extend_from_slice(samples);
            if buf.len() > Self::MAX_SAMPLES {
                let overflow = buf.len() - Self::MAX_SAMPLES;
                buf.drain(..overflow);
            }
        }
    }

    /// Take everything captured so far, leaving the buffer empty.
    pub fn drain(&self) -> Vec<f32> {
        match self.inner.lock() {
            Ok(mut buf) => std::mem::take(&mut *buf),
            Err(_) => Vec::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.inner.lock().map(|b| b.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// A running capture. Dropping it (or calling `stop`) ends the capture thread and the stream.
pub struct Capture {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
    pub device_name: String,
}

impl Capture {
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop();
    }
}

/// List candidate loopback/input devices (for the settings UI).
pub fn list_devices() -> Vec<String> {
    let host = cpal::default_host();
    let mut names = Vec::new();
    if let Ok(devices) = host.input_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                names.push(name);
            }
        }
    }
    // On Windows the loopback source is an *output* device.
    if let Ok(devices) = host.output_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                let tagged = format!("{name} (output/loopback)");
                if !names.contains(&tagged) {
                    names.push(tagged);
                }
            }
        }
    }
    names
}

/// Pick the system-audio loopback device. `prefer` is an optional name substring from settings.
fn pick_device(host: &cpal::Host, prefer: &str) -> Result<(Device, SupportedStreamConfig), String> {
    // Explicit user choice wins (match against both input and output device names).
    if !prefer.trim().is_empty() {
        let needle = prefer.trim().to_lowercase();
        if let Ok(devices) = host.input_devices() {
            for d in devices {
                if d.name().map(|n| n.to_lowercase().contains(&needle)).unwrap_or(false) {
                    let cfg = d
                        .default_input_config()
                        .map_err(|e| format!("device config error: {e}"))?;
                    return Ok((d, cfg));
                }
            }
        }
        #[cfg(target_os = "windows")]
        if let Ok(devices) = host.output_devices() {
            for d in devices {
                if d.name().map(|n| n.to_lowercase().contains(&needle)).unwrap_or(false) {
                    let cfg = d
                        .default_output_config()
                        .map_err(|e| format!("device config error: {e}"))?;
                    return Ok((d, cfg));
                }
            }
        }
        return Err(format!("No capture device matching \"{prefer}\""));
    }

    // Windows: WASAPI loopback lives on the default *output* device.
    #[cfg(target_os = "windows")]
    {
        let device = host
            .default_output_device()
            .ok_or("No default output device for loopback")?;
        let cfg = device
            .default_output_config()
            .map_err(|e| format!("device config error: {e}"))?;
        return Ok((device, cfg));
    }

    // Linux: prefer a PipeWire/PulseAudio "monitor" source (the speaker loopback).
    #[cfg(target_os = "linux")]
    {
        if let Ok(devices) = host.input_devices() {
            for d in devices {
                if d.name().map(|n| n.to_lowercase().contains("monitor")).unwrap_or(false) {
                    let cfg = d
                        .default_input_config()
                        .map_err(|e| format!("device config error: {e}"))?;
                    return Ok((d, cfg));
                }
            }
        }
    }

    // Fallback (macOS virtual cable, or Linux with no monitor exposed): default input device.
    let device = host
        .default_input_device()
        .ok_or("No default input device. On macOS, install a loopback device (e.g. BlackHole) and select it in Settings.")?;
    let cfg = device
        .default_input_config()
        .map_err(|e| format!("device config error: {e}"))?;
    Ok((device, cfg))
}

/// Start capturing system audio into `buffer`. Returns a `Capture` handle that stops on drop.
pub fn start(prefer_device: &str, buffer: SampleBuffer) -> Result<Capture, String> {
    let host = cpal::default_host();
    let (device, supported) = pick_device(&host, prefer_device)?;
    let device_name = device.name().unwrap_or_else(|_| "unknown".into());
    let sample_format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let src_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();

    // cpal `Stream` is not `Send` on every platform, so it must be created and kept alive on a
    // dedicated thread. The thread parks until `stop` is set, then drops the stream.
    let handle = std::thread::Builder::new()
        .name("ghostpen-audio".into())
        .spawn(move || {
            let err_fn = |e| tracing::warn!("audio stream error: {e}");
            let buf = buffer.clone();

            // One callback per sample format; each downmixes to mono and resamples to 16 kHz.
            let stream = match sample_format {
                SampleFormat::F32 => device.build_input_stream(
                    &config,
                    move |data: &[f32], _: &cpal::InputCallbackInfo| {
                        let mono = downmix(data, channels);
                        let resampled = resample(&mono, src_rate, TARGET_RATE);
                        buf.push(&resampled);
                    },
                    err_fn,
                    None,
                ),
                SampleFormat::I16 => device.build_input_stream(
                    &config,
                    move |data: &[i16], _: &cpal::InputCallbackInfo| {
                        let floats: Vec<f32> =
                            data.iter().map(|&s| s as f32 / i16::MAX as f32).collect();
                        let mono = downmix(&floats, channels);
                        let resampled = resample(&mono, src_rate, TARGET_RATE);
                        buf.push(&resampled);
                    },
                    err_fn,
                    None,
                ),
                SampleFormat::U16 => device.build_input_stream(
                    &config,
                    move |data: &[u16], _: &cpal::InputCallbackInfo| {
                        let floats: Vec<f32> = data
                            .iter()
                            .map(|&s| (s as f32 / u16::MAX as f32) * 2.0 - 1.0)
                            .collect();
                        let mono = downmix(&floats, channels);
                        let resampled = resample(&mono, src_rate, TARGET_RATE);
                        buf.push(&resampled);
                    },
                    err_fn,
                    None,
                ),
                other => {
                    tracing::error!("unsupported sample format: {other:?}");
                    return;
                }
            };

            let stream = match stream {
                Ok(s) => s,
                Err(e) => {
                    tracing::error!("failed to build input stream: {e}");
                    return;
                }
            };
            if let Err(e) = stream.play() {
                tracing::error!("failed to start audio stream: {e}");
                return;
            }
            tracing::info!("captions: capturing from {src_rate} Hz / {channels} ch");
            while !stop_thread.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            // Stream stops when dropped here.
            drop(stream);
        })
        .map_err(|e| format!("failed to spawn audio thread: {e}"))?;

    Ok(Capture {
        stop,
        handle: Some(handle),
        device_name,
    })
}

/// Average interleaved channels down to mono.
fn downmix(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Linear resampler from `src_rate` to `dst_rate`. Adequate for speech; keeps deps minimal.
fn resample(input: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if src_rate == dst_rate || input.is_empty() {
        return input.to_vec();
    }
    let ratio = dst_rate as f64 / src_rate as f64;
    let out_len = ((input.len() as f64) * ratio).round() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src_pos = i as f64 / ratio;
        let idx = src_pos.floor() as usize;
        let frac = src_pos - idx as f64;
        let a = input.get(idx).copied().unwrap_or(0.0);
        let b = input.get(idx + 1).copied().unwrap_or(a);
        out.push(a + (b - a) * frac as f32);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_stereo_averages() {
        let stereo = [0.0, 1.0, 0.5, 0.5];
        assert_eq!(downmix(&stereo, 2), vec![0.5, 0.5]);
    }

    #[test]
    fn resample_identity_when_rates_match() {
        let s = vec![0.1, 0.2, 0.3];
        assert_eq!(resample(&s, 16000, 16000), s);
    }

    #[test]
    fn resample_downsamples_length() {
        let s = vec![0.0; 48000];
        let out = resample(&s, 48000, 16000);
        assert!((out.len() as i64 - 16000).abs() <= 1);
    }

    #[test]
    fn sample_buffer_caps_growth() {
        let buf = SampleBuffer::default();
        buf.push(&vec![0.0; SampleBuffer::MAX_SAMPLES + 1000]);
        assert!(buf.len() <= SampleBuffer::MAX_SAMPLES);
    }
}
