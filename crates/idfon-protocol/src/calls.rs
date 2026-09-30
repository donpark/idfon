//! Live-call transcript envelope.
//!
//! The ai-voice-chat holder forwards GPT-Live's input/output transcripts to the
//! caller as `IDFON-CALL/1` message envelopes so the chat view can show the
//! spoken turns as bubbles. Each message is a **snapshot** of the text so far
//! for one `turn_id`; the app upserts by `turn_id` and the `final` flag closes
//! the bubble. Snapshots are throttled by the holder, so a turn produces a
//! handful of messages rather than one per delta.
//!
//! Like the artifact envelopes this rides in message text, so no
//! protocol-version bump is needed.

use serde::{Deserialize, Serialize};

pub const CALL_PREFIX: &str = "IDFON-CALL/1\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CallSpeaker {
    /// The person on the call.
    Caller,
    /// The agent's voice (GPT-Live).
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CallTranscript {
    pub call_id: String,
    pub turn_id: String,
    pub role: CallSpeaker,
    pub text: String,
    #[serde(default)]
    pub r#final: bool,
}

impl CallTranscript {
    pub fn caller(call_id: &str, turn_id: &str, text: &str, r#final: bool) -> Self {
        Self {
            call_id: call_id.to_string(),
            turn_id: turn_id.to_string(),
            role: CallSpeaker::Caller,
            text: text.to_string(),
            r#final,
        }
    }

    pub fn agent(call_id: &str, turn_id: &str, text: &str, r#final: bool) -> Self {
        Self {
            call_id: call_id.to_string(),
            turn_id: turn_id.to_string(),
            role: CallSpeaker::Agent,
            text: text.to_string(),
            r#final,
        }
    }
}

pub fn is_call_transcript(text: &str) -> bool {
    text.starts_with(CALL_PREFIX)
}

pub fn encode_call_transcript(transcript: &CallTranscript) -> Result<String, serde_json::Error> {
    let body = serde_json::to_string(transcript)?;
    Ok(format!("{CALL_PREFIX}{body}"))
}

pub fn decode_call_transcript(text: &str) -> Option<CallTranscript> {
    let body = text.strip_prefix(CALL_PREFIX)?;
    serde_json::from_str(body).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_call_transcript() {
        let transcript = CallTranscript::agent("call-1", "call-1-2", "Hello there.", false);
        let encoded = encode_call_transcript(&transcript).expect("encode");
        assert!(is_call_transcript(&encoded));
        assert_eq!(decode_call_transcript(&encoded), Some(transcript));
    }

    #[test]
    fn rejects_non_call_text() {
        assert!(!is_call_transcript("IDFON-ARTIFACT/1\n{}"));
        assert_eq!(decode_call_transcript("plain text"), None);
    }
}
