//! C-ABI bridge to a Swift-implemented Apple `VoiceEngine` (P6/A1).
//!
//! The Apple engine lives in Swift (`ios/Idfon/OnDeviceVoice.swift`) using
//! `AVSpeechSynthesizer`/`SFSpeechRecognizer`. Rust cannot link a Swift trait
//! object, so the app registers its C functions once
//! (`idfon_voice_set_bindings`) and this module's [`AppleVoiceEngine`]
//! implements the Rust [`VoiceEngine`] seam by calling them.
//!
//! Contract (s16 little-endian mono PCM):
//! - `tts(text, out_rate, out_len)` returns a Swift-owned buffer of s16 mono
//!   samples at `*out_rate`.
//! - `stt(pcm, len, rate, out_text)` returns 0 on success and a Swift-owned
//!   UTF-8 string in `*out_text`.
//! - the matching `free_*` function releases each.
//!
//! Whole-utterance only: the Swift side blocks until synthesis/recognition
//! finishes, so [`TtsSession::finish`] and [`SttSession::finish`] carry the
//! audio. Streaming is a P4 seam concern the future cascade can layer on.

#![cfg(feature = "apple-ffi")]

use std::ffi::{c_char, CStr, CString};
use std::slice;
use std::sync::OnceLock;

use anyhow::{anyhow, Result};

use crate::{
    AudioFormat, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

pub type TtsFn = unsafe extern "C" fn(*const c_char, *mut u32, *mut usize) -> *mut u8;
pub type SttFn = unsafe extern "C" fn(*const u8, usize, u32, *mut *mut c_char) -> i32;
pub type FreeBytesFn = unsafe extern "C" fn(*mut u8, usize);
pub type FreeTextFn = unsafe extern "C" fn(*mut c_char);

/// C functions provided by the Swift app.
#[derive(Debug, Clone, Copy)]
pub struct AppleVoiceBindings {
    pub tts: TtsFn,
    pub stt: SttFn,
    pub free_bytes: FreeBytesFn,
    pub free_text: FreeTextFn,
}

static BINDINGS: OnceLock<AppleVoiceBindings> = OnceLock::new();

/// Register the Swift engine. Idempotent: the first registration wins.
pub fn set_bindings(bindings: AppleVoiceBindings) {
    let _ = BINDINGS.set(bindings);
}

fn bindings() -> Result<AppleVoiceBindings> {
    BINDINGS
        .get()
        .copied()
        .ok_or_else(|| anyhow!("apple voice bindings not registered"))
}

/// The Apple-native engine, backed by the registered Swift functions.
#[derive(Debug, Default, Clone, Copy)]
pub struct AppleVoiceEngine;

impl AppleVoiceEngine {
    pub fn new() -> Self {
        Self
    }
}

impl VoiceEngine for AppleVoiceEngine {
    fn name(&self) -> &str {
        "apple-on-device"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Ok(Box::new(AppleStt {
            format: AudioFormat {
                channels: 1,
                ..format
            },
            pcm: Vec::new(),
        }))
    }

    fn tts(&self, _voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(AppleTts {
            format,
            pending: String::new(),
        }))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(crate::stub::EnergyEndpointer::new(format)))
    }
}

struct AppleTts {
    format: AudioFormat,
    pending: String,
}

impl TtsSession for AppleTts {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>> {
        // The Apple synth is whole-utterance; buffer until finish.
        self.pending.push_str(delta);
        Ok(Vec::new())
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let text = std::mem::take(&mut self.pending);
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        let bindings = bindings()?;
        let text = CString::new(text).map_err(|_| anyhow!("tts text contains a NUL"))?;
        let mut sample_rate = self.format.sample_rate;
        let mut len = 0usize;
        let ptr = unsafe { (bindings.tts)(text.as_ptr(), &mut sample_rate, &mut len) };
        if ptr.is_null() || len < 2 {
            return Err(anyhow!("apple tts produced no audio"));
        }
        let samples = unsafe {
            let bytes = slice::from_raw_parts(ptr, len);
            let samples = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect::<Vec<_>>();
            (bindings.free_bytes)(ptr, len);
            samples
        };
        Ok(vec![PcmChunk {
            format: AudioFormat {
                sample_rate,
                channels: 1,
            },
            samples,
        }])
    }
}

struct AppleStt {
    format: AudioFormat,
    pcm: Vec<i16>,
}

impl SttSession for AppleStt {
    fn push(&mut self, pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
        self.pcm.extend_from_slice(pcm);
        Ok(Vec::new())
    }

    fn flush(&mut self) -> Result<Option<String>> {
        self.transcribe()
    }

    fn finish(&mut self) -> Result<Option<String>> {
        self.transcribe()
    }
}

impl AppleStt {
    fn transcribe(&mut self) -> Result<Option<String>> {
        if self.pcm.is_empty() {
            return Ok(None);
        }
        let bytes =
            unsafe { slice::from_raw_parts(self.pcm.as_ptr() as *const u8, self.pcm.len() * 2) };
        let bindings = bindings()?;
        let mut out: *mut c_char = std::ptr::null_mut();
        let status = unsafe {
            (bindings.stt)(
                bytes.as_ptr(),
                bytes.len(),
                self.format.sample_rate,
                &mut out,
            )
        };
        if status != 0 || out.is_null() {
            return Err(anyhow!("apple stt failed with status {status}"));
        }
        let text = unsafe { CStr::from_ptr(out) }
            .to_string_lossy()
            .into_owned();
        unsafe { (bindings.free_text)(out) };
        self.pcm.clear();
        Ok((!text.trim().is_empty()).then_some(text))
    }
}
