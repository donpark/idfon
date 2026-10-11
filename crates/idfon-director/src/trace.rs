//! Run traces as data (#40). Schema: `docs/voice-agent-loop-contract.md` §4.
//!
//! A trace is one JSON object per turn. The prompt and the tool schemas are
//! **content-addressed** by hash, so a GEPA loop or an RL loop can attribute a
//! change to the exact prompt and schema it ran against. The ids are hashes
//! (not random `uuid`s), so the same turn replays the same trace.

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The prompt version. The tool-schema version.
pub const SCHEMA_VERSION: &str = "1";

/// One step in a turn.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TraceStep {
    /// `model`, `tool_call`, `tool_result`, or `denied`.
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub latency_ms: u128,
    /// The tool-call arguments, for a `tool_call` step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub args: Option<Value>,
    /// Whether a `tool_result` step succeeded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
    /// Why a step was refused, or other step detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// The prompt a run used: id, content hash, and section names.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PromptRef {
    pub id: String,
    pub version: String,
    pub sections: Vec<String>,
}

/// The tool schemas a run offered: schema version and content hash.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolsRef {
    pub schema_version: String,
    pub hash: String,
}

/// The turn input a run saw.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TraceInput {
    pub text: String,
    /// `transcript`, `text`, `crop`, `camera`, ...
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parts: Vec<String>,
    /// Serialized artifact references (`IDFON-REF/1`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refs: Vec<Value>,
}

/// What a run produced.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TraceOutput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speak: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<String>,
}

/// How a run ended.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TraceOutcome {
    /// `ok`, `error`, or `aborted`.
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// The privacy policy of a trace.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Redaction {
    pub policy: String,
    pub local_only: bool,
}

impl Default for Redaction {
    fn default() -> Self {
        Self {
            policy: "local_only".into(),
            local_only: true,
        }
    }
}

/// The tier/provider/model a run used, for the trace.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TraceInfo {
    pub tier: String,
    pub provider: String,
    pub model: String,
}

impl Default for TraceInfo {
    fn default() -> Self {
        Self {
            tier: "on-device".into(),
            provider: "mock".into(),
            model: "mock".into(),
        }
    }
}

/// One turn's trace, per the contract.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TraceRecord {
    pub trace_id: String,
    pub parent_id: Option<String>,
    pub turn_id: String,
    /// The 0-based turn index in the session.
    pub step: u32,
    /// RFC3339 UTC.
    pub ts: String,
    pub tier: String,
    pub provider: String,
    pub model: String,
    pub prompt: PromptRef,
    pub tools: ToolsRef,
    pub input: TraceInput,
    pub steps: Vec<TraceStep>,
    pub output: TraceOutput,
    pub outcome: TraceOutcome,
    pub redaction: Redaction,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, Value>,
}

/// A stable content hash, used to version a prompt or a tool schema.
pub fn content_hash(bytes: &[u8]) -> String {
    format!("blake3:{}", blake3::hash(bytes).to_hex())
}

/// The first 16 hex characters of [`content_hash`], for readable ids.
pub fn short_hash(value: &str) -> String {
    let hash = content_hash(value.as_bytes());
    hash.trim_start_matches("blake3:")
        .chars()
        .take(16)
        .collect()
}

/// The section names of a prompt, from its Markdown headings.
pub fn sections(prompt: &str) -> Vec<String> {
    prompt
        .lines()
        .filter_map(|line| line.strip_prefix("# "))
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .collect()
}

/// RFC3339 UTC for `time`. A small clock helper, so the crate needs no date
/// dependency.
pub fn rfc3339(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (seconds / 86_400) as i64;
    let rem = seconds % 86_400;
    let (hour, minute, second) = (rem / 3_600, (rem % 3_600) / 60, rem % 60);

    // Civil date from days since the Unix epoch (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };

    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn rfc3339_formats_known_times() {
        assert_eq!(rfc3339(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(
            rfc3339(UNIX_EPOCH + Duration::from_secs(1_700_000_000)),
            "2023-11-14T22:13:20Z"
        );
        assert_eq!(
            rfc3339(UNIX_EPOCH + Duration::from_secs(951_782_400)),
            "2000-02-29T00:00:00Z"
        );
    }

    #[test]
    fn sections_read_markdown_headings() {
        let prompt = "# Identity\nYou are.\n# Output rules\nShort.\n## Not a section\n";
        assert_eq!(sections(prompt), vec!["Identity", "Output rules"]);
    }
}
