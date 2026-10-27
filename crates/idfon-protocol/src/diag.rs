//! Diagnostics envelope (`IDFON-DIAG/1`).
//!
//! The app ships diagnostic events to a monitor peer as ordinary messages.
//! The 2026-10-23 wake saga taught the shape: iroh was the only channel that
//! never failed, and remote log access was the binding constraint. Events are
//! batched (a wake burst is a storm — the 403 register loop produced hundreds
//! of lines) and bounded like the other envelopes: a report must not be able
//! to grow without limit.
//!
//! Like the artifact envelopes this rides in message text, so no
//! protocol-version bump is needed. The protocol persists nothing: the
//! monitor decides where the events land (today the daemon's message log,
//! `idfon events`; a filing agent is the follow-up).

use serde::{Deserialize, Serialize};

pub const DIAG_PREFIX: &str = "IDFON-DIAG/1\n";

/// Upper bound on events per report; the app flushes before this.
pub const MAX_DIAG_EVENTS: usize = 64;

/// One diagnostic event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiagEvent {
    /// Unix milliseconds at the event.
    pub ts_ms: u64,
    /// Stable event name, e.g. "push.update", "register.result", "wake".
    pub kind: String,
    /// Free-form facts about the event (per-ref HTTP results, config, …).
    #[serde(default)]
    pub detail: serde_json::Value,
}

/// One batch of events from one device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiagReport {
    /// The sending device: identity id or endpoint id.
    pub device: String,
    /// The app's build stamp (what the field actually runs).
    pub build: String,
    pub events: Vec<DiagEvent>,
}

pub fn is_diag(text: &str) -> bool {
    text.starts_with(DIAG_PREFIX)
}

pub fn encode_diag(report: &DiagReport) -> Result<String, serde_json::Error> {
    let mut bounded = report.clone();
    bounded.events.truncate(MAX_DIAG_EVENTS);
    let body = serde_json::to_string(&bounded)?;
    Ok(format!("{DIAG_PREFIX}{body}"))
}

pub fn decode_diag(text: &str) -> Option<DiagReport> {
    let body = text.strip_prefix(DIAG_PREFIX)?;
    serde_json::from_str(body).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report() -> DiagReport {
        DiagReport {
            device: "device-1".into(),
            build: "2026-10-27.diag1".into(),
            events: vec![DiagEvent {
                ts_ms: 1_761_000_000_000,
                kind: "wake".into(),
                detail: serde_json::json!({"push": "presented"}),
            }],
        }
    }

    #[test]
    fn round_trips_a_report() {
        let encoded = encode_diag(&report()).expect("encode");
        assert!(is_diag(&encoded));
        assert_eq!(decode_diag(&encoded), Some(report()));
    }

    #[test]
    fn rejects_non_diag_text() {
        assert!(!is_diag("IDFON-CALL/1\n{}"));
        assert_eq!(decode_diag("plain text"), None);
    }

    #[test]
    fn a_report_is_bounded() {
        let mut many = report();
        many.events = (0..MAX_DIAG_EVENTS + 10)
            .map(|i| DiagEvent {
                ts_ms: i as u64,
                kind: "tick".into(),
                detail: serde_json::Value::Null,
            })
            .collect();
        let encoded = encode_diag(&many).expect("encode");
        let decoded = decode_diag(&encoded).expect("decode");
        assert_eq!(decoded.events.len(), MAX_DIAG_EVENTS);
    }
}
