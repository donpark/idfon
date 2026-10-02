//! Realtime forwarding: Eve `message.appended` deltas → incremental TTS (F11).
//!
//! Phase P4 (epic #17). The hard parts are deterministic and offline-testable:
//!
//! - **Envelope/artifact stripping** is a state machine, not an LLM: an
//!   `IDFON-*/1` block (artifact, data, room, …) is never spoken, even when a
//!   delta splits the marker across frames.
//! - **Clause batching** emits only at clause boundaries so TTS is fed whole
//!   phrases, not token fragments.
//! - **Retry dedupe** keys on `(turnId, stepIndex, sequence)`; a provider retry
//!   repeats the same triple and must not speak twice.
//! - `reasoning.appended` is never routed here (the forwarder only accepts
//!   [`MessageDelta`]); reasoning is display-only.

use std::collections::HashSet;

use anyhow::Result;

use crate::{PcmChunk, TtsSession};

/// Eve's block coordinate for one output delta. Retries repeat this triple.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DeltaKey {
    pub turn_id: String,
    pub step_index: u64,
    pub sequence: u64,
}

impl DeltaKey {
    pub fn new(turn_id: impl Into<String>, step_index: u64, sequence: u64) -> Self {
        Self {
            turn_id: turn_id.into(),
            step_index,
            sequence,
        }
    }
}

/// One agent message delta, as forwarded from the channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageDelta {
    pub key: DeltaKey,
    pub text: String,
}

impl MessageDelta {
    pub fn new(turn_id: impl Into<String>, step_index: u64, sequence: u64, text: &str) -> Self {
        Self {
            key: DeltaKey::new(turn_id, step_index, sequence),
            text: text.to_string(),
        }
    }
}

/// Deterministic strip of `IDFON-*/1` envelope spans from streamed text.
#[derive(Default)]
pub struct EnvelopeStripper {
    cut: bool,
    pending: String,
}

fn is_envelope_marker(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with("IDFON-") && trimmed.ends_with("/1")
}

impl EnvelopeStripper {
    /// Feed a text fragment; returns the speakable part (envelope spans removed).
    pub fn push(&mut self, text: &str) -> String {
        if self.cut {
            return String::new();
        }
        self.pending.push_str(text);
        let mut out = String::new();
        while let Some(index) = self.pending.find('\n') {
            let line: String = self.pending.drain(..=index).collect();
            if is_envelope_marker(&line) {
                self.cut = true;
                return out;
            }
            out.push_str(&line);
        }
        // A trailing partial line is speakable unless it could still become an
        // envelope marker (`IDFON-` is the only ambiguous prefix).
        if !self.pending.starts_with("IDFON-") {
            out.push_str(&self.pending);
            self.pending.clear();
        }
        out
    }

    /// Flush at end of turn.
    pub fn finish(&mut self) -> String {
        if self.cut {
            return String::new();
        }
        let rest = std::mem::take(&mut self.pending);
        if is_envelope_marker(&rest) {
            self.cut = true;
            return String::new();
        }
        rest
    }
}

/// Accumulates text and emits whole clauses (sentence-ish) for TTS.
#[derive(Default)]
pub struct ClauseBatcher {
    pending: String,
}

impl ClauseBatcher {
    /// Feed text; returns complete clauses.
    pub fn push(&mut self, text: &str) -> Vec<String> {
        self.pending.push_str(text);
        let mut clauses = Vec::new();
        let mut start = 0;
        for (index, character) in self.pending.char_indices() {
            if matches!(character, '.' | '!' | '?' | ';' | '\n') {
                let end = index + character.len_utf8();
                clauses.push(self.pending[start..end].trim().to_string());
                start = end;
            }
        }
        if start > 0 {
            self.pending.drain(..start);
        }
        clauses.retain(|clause| !clause.is_empty());
        clauses
    }

    /// Flush the trailing fragment.
    pub fn finish(&mut self) -> Option<String> {
        let tail = std::mem::take(&mut self.pending);
        let tail = tail.trim();
        (!tail.is_empty()).then(|| tail.to_string())
    }
}

/// Streams agent deltas into a TTS session: strip → dedupe → batch → synthesize.
///
/// Audio is produced **incrementally**: [`push`] returns chunks as soon as a
/// clause completes, before the turn finishes (F11/N2).
pub struct StreamingSpeaker {
    tts: Box<dyn TtsSession>,
    stripper: EnvelopeStripper,
    batcher: ClauseBatcher,
    seen: HashSet<DeltaKey>,
}

impl StreamingSpeaker {
    pub fn new(tts: Box<dyn TtsSession>) -> Self {
        Self {
            tts,
            stripper: EnvelopeStripper::default(),
            batcher: ClauseBatcher::default(),
            seen: HashSet::new(),
        }
    }

    /// Feed one delta. Repeats of a `(turnId, stepIndex, sequence)` triple are
    /// ignored (provider retry), so text is never spoken twice.
    pub fn push(&mut self, delta: MessageDelta) -> Result<Vec<PcmChunk>> {
        if !self.seen.insert(delta.key.clone()) {
            return Ok(Vec::new());
        }
        let speakable = self.stripper.push(&delta.text);
        let clauses = self.batcher.push(&speakable);
        self.synthesize_clauses(clauses)
    }

    /// Flush the stripper/batcher and the TTS session at end of turn.
    pub fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let tail = self.stripper.finish();
        let clauses = self.batcher.push(&tail);
        let mut out = self.synthesize_clauses(clauses)?;
        if let Some(clause) = self.batcher.finish() {
            out.extend(self.tts.push_text(&clause)?);
        }
        out.extend(self.tts.finish()?);
        Ok(out)
    }

    fn synthesize_clauses(&mut self, clauses: Vec<String>) -> Result<Vec<PcmChunk>> {
        let mut chunks = Vec::new();
        for clause in clauses {
            chunks.extend(self.tts.push_text(&clause)?);
        }
        Ok(chunks)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AudioFormat, StubVoiceEngine, VoiceEngine};

    fn speaker() -> StreamingSpeaker {
        let tts = StubVoiceEngine::new()
            .tts("default", AudioFormat::PCM_24K_MONO)
            .unwrap();
        StreamingSpeaker::new(tts)
    }

    #[test]
    fn first_audio_precedes_turn_completion() {
        let mut speaker = speaker();
        // A single complete clause produces audio mid-turn.
        let chunks = speaker
            .push(MessageDelta::new("turn-1", 0, 0, "Hello there."))
            .unwrap();
        assert!(!chunks.is_empty(), "audio must start before finish()");
        // finish still yields whatever tail remains.
        assert!(speaker.finish().is_ok());
    }

    #[test]
    fn provider_retry_does_not_speak_twice() {
        let mut speaker = speaker();
        let first = speaker
            .push(MessageDelta::new("turn-1", 0, 0, "One."))
            .unwrap();
        assert!(!first.is_empty());
        // Same coordinate again (retry) is ignored.
        let retry = speaker
            .push(MessageDelta::new("turn-1", 0, 0, "One."))
            .unwrap();
        assert!(retry.is_empty());
        // A different sequence still speaks.
        let next = speaker
            .push(MessageDelta::new("turn-1", 0, 1, "Two."))
            .unwrap();
        assert!(!next.is_empty());
    }

    #[test]
    fn envelopes_are_never_spoken_even_when_split_across_deltas() {
        let mut speaker = speaker();
        assert!(
            speaker
                .push(MessageDelta::new("turn-1", 0, 0, "Here is the chart."))
                .unwrap()
                .len()
                > 0
        );
        // The marker arrives split across two deltas; nothing after it speaks.
        assert!(speaker
            .push(MessageDelta::new("turn-1", 0, 1, "\nIDFON-ART"))
            .unwrap()
            .is_empty());
        assert!(speaker
            .push(MessageDelta::new("turn-1", 0, 2, "IFACT/1\nticket=blob"))
            .unwrap()
            .is_empty());
        assert!(speaker.finish().unwrap().is_empty());
    }

    #[test]
    fn batcher_emits_whole_clauses_and_flushes_the_tail() {
        let mut batcher = ClauseBatcher::default();
        assert!(batcher.push("Two plus").is_empty());
        assert_eq!(batcher.push(" two is four. And").len(), 1);
        assert_eq!(batcher.finish().as_deref(), Some("And"));
    }
}
