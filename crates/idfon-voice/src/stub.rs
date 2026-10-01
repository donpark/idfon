//! Deterministic offline engine: silence instead of speech, no network, no
//! credentials. For tests and the no-network pipeline check only.

use anyhow::Result;

use crate::{
    AudioFormat, EndpointEvent, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession,
    VoiceEngine,
};

/// Engine id reported by [`StubVoiceEngine::name`].
pub const STUB: &str = "stub";

/// A `VoiceEngine` that never calls a provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct StubVoiceEngine;

impl StubVoiceEngine {
    pub fn new() -> Self {
        Self
    }
}

impl VoiceEngine for StubVoiceEngine {
    fn name(&self) -> &str {
        STUB
    }

    fn stt(&self, _format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Ok(Box::new(StubStt))
    }

    fn tts(&self, _voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(StubTts {
            format,
            pending: String::new(),
        }))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(EnergyEndpointer::new(format)))
    }
}

/// STT stub: accepts audio, transcribes nothing.
struct StubStt;

impl SttSession for StubStt {
    fn push(&mut self, _pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
        Ok(Vec::new())
    }

    fn finish(&mut self) -> Result<Option<String>> {
        Ok(None)
    }
}

/// TTS stub: emits silence whose length tracks the spoken text, batched at
/// sentence boundaries. It never produces speech.
struct StubTts {
    format: AudioFormat,
    pending: String,
}

impl StubTts {
    /// ~50 ms of silence per word, at least 100 ms, so every non-empty text
    /// yields a non-empty chunk.
    fn silence_for(&self, text: &str) -> PcmChunk {
        let words = text.split_whitespace().count().max(1);
        let rate = self.format.sample_rate as usize;
        let frames = (rate / 20 * words).max(rate / 10);
        PcmChunk::silence(self.format, frames * self.format.channels as usize)
    }
}

impl TtsSession for StubTts {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>> {
        self.pending.push_str(delta);
        let mut chunks = Vec::new();
        // Emit each complete sentence as it appears; keep the trailing fragment.
        while let Some(index) = self
            .pending
            .char_indices()
            .find(|(_, c)| matches!(c, '.' | '!' | '?' | '\n'))
            .map(|(index, _)| index)
        {
            let sentence: String = self.pending.drain(..=index).collect();
            if !sentence.trim().is_empty() {
                chunks.push(self.silence_for(&sentence));
            }
        }
        Ok(chunks)
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let text = std::mem::take(&mut self.pending);
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![self.silence_for(&text)])
    }
}

/// Deterministic energy endpointing: speech starts on a loud frame and ends
/// after a sustained quiet tail. Mirrors the energy gate the call path already
/// uses (`|s16| > 300`); good enough for the offline gate, replaced by the
/// provider's semantic VAD in P2.
struct EnergyEndpointer {
    format: AudioFormat,
    speaking: bool,
    quiet_frames: usize,
    threshold: i16,
}

const ENERGY_THRESHOLD: i16 = 300;
const ENDPOINT_QUIET_MS: usize = 800;

impl EnergyEndpointer {
    fn new(format: AudioFormat) -> Self {
        Self {
            format,
            speaking: false,
            quiet_frames: 0,
            threshold: ENERGY_THRESHOLD,
        }
    }

    fn frames(&self, samples: usize) -> usize {
        samples / self.format.channels.max(1) as usize
    }

    fn quiet_frames_for_endpoint(&self) -> usize {
        self.format.sample_rate as usize * ENDPOINT_QUIET_MS / 1000
    }
}

impl Endpointer for EnergyEndpointer {
    fn push(&mut self, pcm: &[i16]) -> Result<Option<EndpointEvent>> {
        if pcm.is_empty() {
            return Ok(None);
        }
        let loud = pcm
            .iter()
            .any(|sample| sample.unsigned_abs() > self.threshold as u16);
        if loud {
            self.quiet_frames = 0;
            if !self.speaking {
                self.speaking = true;
                return Ok(Some(EndpointEvent::SpeechStarted));
            }
            return Ok(None);
        }
        if !self.speaking {
            return Ok(None);
        }
        self.quiet_frames += self.frames(pcm.len());
        if self.quiet_frames >= self.quiet_frames_for_endpoint() {
            self.speaking = false;
            self.quiet_frames = 0;
            return Ok(Some(EndpointEvent::SpeechEnded));
        }
        Ok(None)
    }

    fn reset(&mut self) {
        self.speaking = false;
        self.quiet_frames = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpointer_fires_on_speech_then_quiet_tail() {
        let mut endpointer = EnergyEndpointer::new(AudioFormat::PCM_24K_MONO);
        assert_eq!(
            endpointer.push(&[1_000; 480]).unwrap(),
            Some(EndpointEvent::SpeechStarted)
        );
        // 400 ms of silence is not yet end-of-turn.
        assert_eq!(endpointer.push(&[0; 9_600]).unwrap(), None);
        // Crossing 800 ms does.
        assert_eq!(
            endpointer.push(&[0; 9_600]).unwrap(),
            Some(EndpointEvent::SpeechEnded)
        );
    }

    #[test]
    fn tts_batches_at_sentence_boundaries() {
        let engine = StubVoiceEngine::new();
        let mut tts = engine.tts("default", AudioFormat::PCM_24K_MONO).unwrap();
        let first = tts.push_text("One. Two is longer").unwrap();
        assert_eq!(first.len(), 1, "first sentence emits immediately");
        assert!(first[0].samples.iter().all(|s| *s == 0));
        let rest = tts.finish().unwrap();
        assert_eq!(rest.len(), 1, "trailing fragment flushes at finish");
    }
}
