//! Durable agent outputs (artifacts) and selections into them (references).
//!
//! An artifact is a first-class result the user can open, annotate, and ask
//! about — not just a file attachment. A reference pins a selection inside one
//! (a text range, an image region, a time range, a JSON pointer, a DOM path) so
//! a multimodal turn can carry "this part of that artifact" alongside voice or
//! text.
//!
//! Both travel as message-text envelopes (`IDFON-ARTIFACT/1`, `IDFON-REF/1`),
//! so no protocol-version bump is needed and a peer that does not know them sees
//! an unknown `IDFON-*/1` envelope as plain text.

use serde::{Deserialize, Serialize};

pub const ARTIFACT_PREFIX: &str = "IDFON-ARTIFACT/1\n";
pub const REFERENCE_PREFIX: &str = "IDFON-REF/1\n";

/// Coarse class of an artifact, used to pick a detail view. `mime` stays
/// authoritative for the bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    /// Text or paginated document (markdown, PDF, plain text).
    Document,
    Image,
    Audio,
    Video,
    /// Structured data (JSON, CSV, a json-render spec).
    Data,
    /// Rendered markup to show in a web view.
    Html,
    /// A live stream referenced by a stream ticket rather than a blob.
    Live,
}

/// A durable agent output.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Artifact {
    pub artifact_id: String,
    pub kind: ArtifactKind,
    pub mime: String,
    pub title: String,
    pub size_bytes: u64,
    /// Content address (iroh blob ticket). Absent for live artifacts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blob_ticket: Option<String>,
    /// The turn that produced it, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    /// Renderer hints (schema, catalog id, dimensions, live stream ticket, ...).
    #[serde(default, skip_serializing_if = "serde_json::Value::is_null")]
    pub metadata: serde_json::Value,
    /// RFC 3339 timestamp.
    pub created_at: String,
}

impl Artifact {
    pub fn validate(&self) -> Result<(), ArtifactError> {
        for (field, value) in [
            ("artifact_id", &self.artifact_id),
            ("title", &self.title),
            ("mime", &self.mime),
            ("created_at", &self.created_at),
        ] {
            if value.trim().is_empty() {
                return Err(ArtifactError::Malformed(format!("{field} is empty")));
            }
        }
        if self.blob_ticket.is_none() && self.kind != ArtifactKind::Live {
            return Err(ArtifactError::Malformed(
                "a non-live artifact needs a blob ticket".into(),
            ));
        }
        Ok(())
    }
}

/// A selection inside an artifact. Geometry is normalized to `[0, 1]` so it
/// survives zooming and differing render sizes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ArtifactSelector {
    /// The artifact as a whole.
    Whole,
    /// A range in text, as UTF-8 byte offsets.
    Text {
        start: u64,
        end: u64,
        /// The selected text, for display and for the agent when the source is
        /// unavailable.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        quote: Option<String>,
    },
    /// A rectangle on an image or a page of a document.
    Region {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        page: Option<u32>,
    },
    /// A span in audio or video.
    TimeRange { start_ms: u64, end_ms: u64 },
    /// A location in structured data (RFC 6901).
    JsonPointer { pointer: String },
    /// A node in rendered markup.
    Element { path: String },
}

impl ArtifactSelector {
    pub fn validate(&self) -> Result<(), ArtifactError> {
        let invalid = |message: &str| Err(ArtifactError::InvalidSelector(message.to_owned()));
        match self {
            ArtifactSelector::Whole => Ok(()),
            ArtifactSelector::Text { start, end, .. } => {
                if end > start {
                    Ok(())
                } else {
                    invalid("text range is empty")
                }
            }
            ArtifactSelector::Region {
                x,
                y,
                width,
                height,
                ..
            } => {
                let unit = |value: f64| (0.0..=1.0).contains(&value);
                let inside = *x + *width <= 1.0 + f64::EPSILON && *y + *height <= 1.0 + f64::EPSILON;
                if unit(*x) && unit(*y) && *width > 0.0 && *height > 0.0 && inside {
                    Ok(())
                } else {
                    invalid("region is outside the unit square")
                }
            }
            ArtifactSelector::TimeRange { start_ms, end_ms } => {
                if end_ms > start_ms {
                    Ok(())
                } else {
                    invalid("time range is empty")
                }
            }
            ArtifactSelector::JsonPointer { pointer } => {
                if pointer.is_empty() || pointer.starts_with('/') {
                    Ok(())
                } else {
                    invalid("json pointer must be empty or start with /")
                }
            }
            ArtifactSelector::Element { path } => {
                if path.is_empty() {
                    invalid("element path is empty")
                } else {
                    Ok(())
                }
            }
        }
    }
}

/// A pointer into an artifact, optionally with a note about the selection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactRef {
    pub artifact_id: String,
    pub selector: ArtifactSelector,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl ArtifactRef {
    pub fn validate(&self) -> Result<(), ArtifactError> {
        if self.artifact_id.trim().is_empty() {
            return Err(ArtifactError::InvalidSelector(
                "artifact id is empty".into(),
            ));
        }
        self.selector.validate()
    }
}

/// A user turn that carries one or more artifact selections.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageReference {
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refs: Vec<ArtifactRef>,
}

impl MessageReference {
    pub fn validate(&self) -> Result<(), ArtifactError> {
        if self.refs.is_empty() {
            return Err(ArtifactError::InvalidSelector("no references".into()));
        }
        for reference in &self.refs {
            reference.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ArtifactError {
    #[error("invalid selector: {0}")]
    InvalidSelector(String),
    #[error("malformed artifact envelope: {0}")]
    Malformed(String),
}

pub fn is_artifact(text: &str) -> bool {
    text.starts_with(ARTIFACT_PREFIX)
}

pub fn is_reference(text: &str) -> bool {
    text.starts_with(REFERENCE_PREFIX)
}

pub fn encode_artifact(artifact: &Artifact) -> Result<String, ArtifactError> {
    artifact.validate()?;
    let body = serde_json::to_string(artifact).map_err(|e| ArtifactError::Malformed(e.to_string()))?;
    Ok(format!("{ARTIFACT_PREFIX}{body}"))
}

pub fn decode_artifact(text: &str) -> Result<Artifact, ArtifactError> {
    let body = text
        .strip_prefix(ARTIFACT_PREFIX)
        .ok_or_else(|| ArtifactError::Malformed("not an artifact envelope".into()))?;
    let artifact: Artifact =
        serde_json::from_str(body).map_err(|e| ArtifactError::Malformed(e.to_string()))?;
    artifact.validate()?;
    Ok(artifact)
}

pub fn encode_reference(reference: &MessageReference) -> Result<String, ArtifactError> {
    reference.validate()?;
    let body =
        serde_json::to_string(reference).map_err(|e| ArtifactError::Malformed(e.to_string()))?;
    Ok(format!("{REFERENCE_PREFIX}{body}"))
}

pub fn decode_reference(text: &str) -> Result<MessageReference, ArtifactError> {
    let body = text
        .strip_prefix(REFERENCE_PREFIX)
        .ok_or_else(|| ArtifactError::Malformed("not a reference envelope".into()))?;
    let reference: MessageReference =
        serde_json::from_str(body).map_err(|e| ArtifactError::Malformed(e.to_string()))?;
    reference.validate()?;
    Ok(reference)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artifact() -> Artifact {
        Artifact {
            artifact_id: "art-1".into(),
            kind: ArtifactKind::Data,
            mime: "application/json".into(),
            title: "Q3 summary".into(),
            size_bytes: 42,
            blob_ticket: Some("blobabc".into()),
            source_message_id: Some("msg-1".into()),
            conversation: None,
            metadata: serde_json::json!({"renderer": "json-render"}),
            created_at: "2026-09-29T00:00:00Z".into(),
        }
    }

    #[test]
    fn artifact_round_trips() {
        let encoded = encode_artifact(&artifact()).unwrap();
        assert!(is_artifact(&encoded));
        assert_eq!(decode_artifact(&encoded).unwrap(), artifact());
    }

    #[test]
    fn artifact_requires_content_unless_live() {
        let mut missing = artifact();
        missing.blob_ticket = None;
        assert!(encode_artifact(&missing).is_err());

        let mut live = missing;
        live.kind = ArtifactKind::Live;
        assert!(encode_artifact(&live).is_ok());
    }

    #[test]
    fn reference_round_trips_every_selector() {
        for selector in [
            ArtifactSelector::Whole,
            ArtifactSelector::Text {
                start: 3,
                end: 9,
                quote: Some("region".into()),
            },
            ArtifactSelector::Region {
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4,
                page: Some(2),
            },
            ArtifactSelector::TimeRange {
                start_ms: 100,
                end_ms: 900,
            },
            ArtifactSelector::JsonPointer {
                pointer: "/rows/3".into(),
            },
            ArtifactSelector::Element {
                path: "body > table:nth-child(2)".into(),
            },
        ] {
            let reference = MessageReference {
                text: "what is this?".into(),
                refs: vec![ArtifactRef {
                    artifact_id: "art-1".into(),
                    selector,
                    note: None,
                }],
            };
            let encoded = encode_reference(&reference).unwrap();
            assert!(is_reference(&encoded));
            assert_eq!(decode_reference(&encoded).unwrap(), reference);
        }
    }

    #[test]
    fn invalid_selections_are_rejected() {
        assert!(ArtifactSelector::Text {
            start: 9,
            end: 3,
            quote: None
        }
        .validate()
        .is_err());
        assert!(ArtifactSelector::Region {
            x: 0.8,
            y: 0.0,
            width: 0.5,
            height: 0.5,
            page: None
        }
        .validate()
        .is_err());
        assert!(ArtifactSelector::Region {
            x: -0.1,
            y: 0.0,
            width: 0.5,
            height: 0.5,
            page: None
        }
        .validate()
        .is_err());
        assert!(ArtifactSelector::TimeRange {
            start_ms: 5,
            end_ms: 5
        }
        .validate()
        .is_err());
        assert!(ArtifactSelector::JsonPointer {
            pointer: "rows/3".into()
        }
        .validate()
        .is_err());
        assert!(ArtifactSelector::Element { path: String::new() }
            .validate()
            .is_err());
    }

    #[test]
    fn a_reference_needs_at_least_one_ref() {
        let reference = MessageReference {
            text: "hello".into(),
            refs: Vec::new(),
        };
        assert!(encode_reference(&reference).is_err());
    }

    #[test]
    fn plain_text_is_not_an_envelope() {
        assert!(decode_artifact("just text").is_err());
        assert!(decode_reference("just text").is_err());
        assert!(!is_artifact("just text"));
    }
}
