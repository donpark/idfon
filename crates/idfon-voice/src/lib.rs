//! Provider seam for the voice side-channel (epic #17, phase P1).
//!
//! The voice service turns agent text into speech and caller speech into
//! signed user turns, but it never owns content: **the service boundary is
//! text** (`docs/voice-side-channel.md`). This crate is the interchangeable
//! engine seam behind that boundary — STT, TTS, and endpointing — so the
//! cascade can swap Apple-native, model-based, and cloud providers without
//! touching the channel or any agent (`F3`/`N3`).
//!
//! Shape:
//!
//! - [`VoiceEngine`] is a stateless factory (`Send + Sync`, `&self`) so one
//!   instance can be shared per host instead of one process per holder (N3).
//! - A streaming session is a boxed [`SttSession`], [`TtsSession`], or
//!   [`Endpointer`]. Sessions hold per-call state; the engine does not.
//! - [`stub::StubVoiceEngine`] is a deterministic, offline, no-credentials
//!   engine for tests and the no-network pipeline check. It emits silence,
//!   not speech, and must never be a production default.
//!
//! This phase ships the seam and the stub only; real providers land in P6/P7.

use std::path::Path;

use anyhow::Result;

pub mod listen;
pub mod stub;
pub mod wav;

pub use listen::{EndpointAuthority, ListenOutput, ListenSession};
pub use stub::StubVoiceEngine;
pub use wav::write_pcm_wav;

/// PCM layout shared by every engine and the media plane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioFormat {
    pub sample_rate: u32,
    pub channels: u16,
}

impl AudioFormat {
    /// GPT-Live and the existing call path use 24 kHz mono s16le.
    pub const PCM_24K_MONO: Self = Self {
        sample_rate: 24_000,
        channels: 1,
    };
    /// Caller recordings / the media plane use 48 kHz mono.
    pub const PCM_48K_MONO: Self = Self {
        sample_rate: 48_000,
        channels: 1,
    };

    pub fn bytes_per_sample(&self) -> usize {
        2
    }

    pub fn frame_bytes(&self) -> usize {
        self.bytes_per_sample() * self.channels as usize
    }
}

/// One STT result. `Partial` is replaceable and never enters agent context;
/// only `Final` is acted on (F2/F7).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptEvent {
    Partial(String),
    Final(String),
}

/// endpointing transition (F3). Exactly one endpointer is authoritative per
/// topology; the non-authoritative one may only feed barge-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointEvent {
    SpeechStarted,
    SpeechEnded,
}

/// A run of interleaved s16 samples ready for playback or wrapping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PcmChunk {
    pub format: AudioFormat,
    pub samples: Vec<i16>,
}

impl PcmChunk {
    pub fn silence(format: AudioFormat, samples: usize) -> Self {
        Self {
            format,
            samples: vec![0; samples],
        }
    }
}

/// Streaming speech-to-text for one listening session.
pub trait SttSession: Send {
    /// Feed interleaved s16 PCM in the session's format; return any events the
    /// provider produced (zero or more partials, at most one final per turn).
    fn push(&mut self, pcm: &[i16]) -> Result<Vec<TranscriptEvent>>;
    /// End the current utterance **without ending the session**, returning any
    /// buffered final text. Used when an authoritative endpointer (not the
    /// provider's own VAD) closes a turn. Defaults to [`finish`] for providers
    /// that cannot separate the two.
    fn flush(&mut self) -> Result<Option<String>> {
        self.finish()
    }
    /// Flush provider state at end of call; returns a trailing final if any.
    fn finish(&mut self) -> Result<Option<String>>;
}

/// Streaming text-to-speech for one speaking turn.
///
/// The caller feeds agent **deltas** (F11); the session batches them to
/// clause/sentence boundaries and returns PCM as it becomes available.
pub trait TtsSession: Send {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>>;
    /// Flush any buffered text; returns the remaining audio.
    fn finish(&mut self) -> Result<Vec<PcmChunk>>;
}

/// End-of-turn detector for one listening session (F3).
pub trait Endpointer: Send {
    /// Feed the same PCM the STT session sees; report a transition if any.
    fn push(&mut self, pcm: &[i16]) -> Result<Option<EndpointEvent>>;
    fn reset(&mut self);
}

/// The provider seam: a stateless, shareable factory for the three sessions.
///
/// One engine per host (N3); sessions are cheap per-call values. Implementors
/// choose the provider family (Apple-native, model-based, cloud); the seam
/// deliberately exposes no provider-specific types.
pub trait VoiceEngine: Send + Sync {
    /// Stable provider id for logs and the model registry.
    fn name(&self) -> &str;
    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>>;
    /// `voice` resolves against the voice registry (F8); the stub ignores it.
    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>>;
    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>>;
}

/// Deterministic offline pipeline used by the no-network check: text → PCM →
/// WAV. No engine process, credentials, or network involved.
pub fn synthesize_to_wav(
    engine: &dyn VoiceEngine,
    text: &str,
    voice: &str,
    format: AudioFormat,
    path: &Path,
) -> Result<usize> {
    let mut tts = engine.tts(voice, format)?;
    let mut samples = Vec::new();
    for chunk in tts.push_text(text)? {
        samples.extend(chunk.samples);
    }
    for chunk in tts.finish()? {
        samples.extend(chunk.samples);
    }
    write_pcm_wav(path, format, &samples)?;
    Ok(samples.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The offline gate: a stub engine turns text into a real PCM WAV with no
    /// network or credentials. Fails if TTS plumbing, batching, or the WAV
    /// writer breaks.
    #[test]
    fn stub_text_to_pcm_to_wav_is_offline_and_valid() {
        let engine = StubVoiceEngine::new();
        let path = std::env::temp_dir().join(format!(
            "idfon-voice-pipeline-test-{}.wav",
            std::process::id()
        ));
        let samples = synthesize_to_wav(
            &engine,
            "Two plus two is four. Anything else?",
            "default",
            AudioFormat::PCM_24K_MONO,
            &path,
        )
        .expect("pipeline");
        assert!(samples > 0);

        let bytes = std::fs::read(&path).expect("read wav");
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[36..40], b"data");
        let rate = u32::from_le_bytes(bytes[24..28].try_into().unwrap());
        let channels = u16::from_le_bytes(bytes[22..24].try_into().unwrap());
        let data_len = u32::from_le_bytes(bytes[40..44].try_into().unwrap());
        assert_eq!((rate, channels), (24_000, 1));
        assert_eq!(data_len as usize, samples * 2);
        assert_eq!(bytes.len(), 44 + samples * 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn stub_is_a_usable_engine_without_credentials() {
        let engine = StubVoiceEngine::new();
        assert_eq!(engine.name(), "stub");
        assert!(engine.stt(AudioFormat::PCM_24K_MONO).is_ok());
        assert!(engine.tts("default", AudioFormat::PCM_24K_MONO).is_ok());
        assert!(engine.endpointer(AudioFormat::PCM_24K_MONO).is_ok());
    }
}
