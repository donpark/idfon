//! Voice C ABI for the native shells.
//!
//! - **Filters (all Apple platforms)**: `idfon_voice_is_cancellable` and
//!   `idfon_voice_is_echo` reuse the Rust P5 barge-in/echo rules so the shells
//!   do not reimplement them.
//! - **Apple engine bridge (iOS)**: the app registers its Swift engine with
//!   `idfon_voice_set_bindings`; `idfon_voice_apple_selftest` runs a full
//!   TTS -> PCM -> STT round trip through the Rust seam and returns the
//!   transcript (or `error:...`). Free the result with `rust_free_string`.

use std::ffi::{c_char, CStr};

/// Barge-in filter (P5): whether `text` may cancel playback. The client owns
/// the barge-in state; this reuses the Rust rule (backchannel/sub-minimum and
/// the tool-action window never cancel).
#[no_mangle]
pub extern "C" fn idfon_voice_is_cancellable(
    text: *const c_char,
    playing: u8,
    in_tool_window: u8,
) -> u8 {
    if text.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    u8::from(idfon_voice::bargein::is_cancellable(
        &text,
        playing != 0,
        in_tool_window != 0,
    ))
}

/// Text-layer echo check (P5): nonzero when `heard` is our own `spoken` text.
#[no_mangle]
pub extern "C" fn idfon_voice_is_echo(spoken: *const c_char, heard: *const c_char) -> u8 {
    if spoken.is_null() || heard.is_null() {
        return 0;
    }
    let spoken = unsafe { CStr::from_ptr(spoken) }.to_string_lossy();
    let heard = unsafe { CStr::from_ptr(heard) }.to_string_lossy();
    let mut suppressor = idfon_voice::echo::EchoSuppressor::new();
    suppressor.set_spoken(&spoken);
    u8::from(suppressor.is_echo(&heard))
}

#[cfg(target_os = "ios")]
mod engine {
    use std::ffi::{c_char, CString};

    use anyhow::{bail, Result};
    use idfon_voice::apple_ffi::{
        set_bindings, AppleVoiceBindings, AppleVoiceEngine, FreeBytesFn, FreeTextFn, SttFn, TtsFn,
    };
    use idfon_voice::{AudioFormat, VoiceEngine};

    /// Register the Swift engine's C functions. Returns 0 on success.
    #[no_mangle]
    pub extern "C" fn idfon_voice_set_bindings(
        tts: TtsFn,
        stt: SttFn,
        free_bytes: FreeBytesFn,
        free_text: FreeTextFn,
    ) -> i32 {
        set_bindings(AppleVoiceBindings {
            tts,
            stt,
            free_bytes,
            free_text,
        });
        0
    }

    /// Runs the Rust seam against the Swift Apple engine; returns a Rust-owned
    /// C string (transcript, or `error:...`). Requires the bindings to be set.
    #[no_mangle]
    pub extern "C" fn idfon_voice_apple_selftest() -> *mut c_char {
        let text = match run() {
            Ok(transcript) => transcript,
            Err(error) => format!("error:{error:#}"),
        };
        CString::new(text)
            .unwrap_or_default()
            .into_raw()
    }

    fn run() -> Result<String> {
        eprintln!("[idfon voice] seam: tts start");
        let engine = AppleVoiceEngine::new();
        let mut tts = engine.tts("default", AudioFormat::PCM_24K_MONO)?;
        let phrase = "the quick brown fox jumps over the lazy dog";
        let mut chunks = tts.push_text(phrase)?;
        chunks.extend(tts.finish()?);

        let format = chunks
            .first()
            .map(|chunk| chunk.format)
            .unwrap_or(AudioFormat::PCM_24K_MONO);
        let samples: Vec<i16> = chunks.into_iter().flat_map(|chunk| chunk.samples).collect();
        eprintln!(
            "[idfon voice] seam: tts samples={} rate={}",
            samples.len(),
            format.sample_rate
        );
        if samples.is_empty() {
            bail!("tts produced no samples");
        }

        eprintln!("[idfon voice] seam: stt start");
        let mut stt = engine.stt(format)?;
        stt.push(&samples)?;
        let transcript = stt.finish()?.unwrap_or_default();
        if transcript.trim().is_empty() {
            bail!("stt produced no transcript");
        }
        Ok(transcript)
    }
}
