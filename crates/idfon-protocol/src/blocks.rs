//! Reply blocks: the typed pieces a reply is made of.
//!
//! A reply is a visible preamble plus `IDFON-*/1` envelopes, in the order the
//! agent produced them (`docs/reply-blocks.md`). Those envelopes already are
//! blocks. This module names them, so every shell renders the same set the same
//! way, and gives each block an id, so a later block can *replace* an earlier
//! one (a model revising what it said) instead of stacking up.
//!
//! Fail-open, twice over:
//!
//! - An envelope this module does not name is kept verbatim
//!   ([`BlockBody::Unparsed`]). The shells still read their own kinds; the
//!   point of the model is not to lose anything it has not learned yet.
//! - A block that does not validate (empty spoken text, an artifact with no
//!   ticket, a render spec that is not a spec) also becomes `Unparsed`, so a
//!   shell never tries to draw garbage.
//!
//! The envelope vocabulary here must stay in step with the shells' splitter
//! (`ios/Idfon/Models.swift` `MessageBody.prefixes` and the mac twin): a
//! header one side knows and the other does not is a block that gets cut in the
//! wrong place.

use serde::Deserialize;
use serde_json::Value;

use crate::artifacts::{
    decode_artifact, decode_reference, encode_artifact, encode_reference, Artifact, ArtifactError,
    ArtifactSelector, MessageReference,
};

/// The headers a reply can be split on. Keep in step with the shells.
pub const ENVELOPE_HEADERS: [&str; 13] = [
    "IDFON-ARTIFACT/1\n",
    "IDFON-REF/1\n",
    "IDFON-POINT/1\n",
    "IDFON-SHOW/1\n",
    "IDFON-SCREENSHOT/1\n",
    "IDFON-DATA/1\n",
    "IDFON-SPEAK/1\n",
    "IDFON-RENDER/1\n",
    "IDFON-RECORDING/1\n",
    "IDFON-FILE/1\n",
    "IDFON-CALL/1\n",
    "IDFON-LIVE/1\n",
    "IDFON-INVITE/1\n",
];

/// The header of a render block: a declarative view the app draws natively.
pub const RENDER_HEADER: &str = "IDFON-RENDER/1\n";

/// A render spec is bounded like the shells bound it: a reply must not be able
/// to make a shell build an unbounded view tree.
pub const MAX_RENDER_BYTES: usize = 64 * 1024;
/// Upper bound on elements in a render spec.
pub const MAX_RENDER_ELEMENTS: usize = 200;

/// One piece of a reply.
#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    /// Stable within the reply. Two blocks with the same id are the same block,
    /// the later one current (see [`upsert`]).
    pub id: String,
    pub body: BlockBody,
}

/// What a block is.
#[derive(Clone, Debug, PartialEq)]
pub enum BlockBody {
    /// Text the caller only sees: the reply's preamble.
    Text { text: String },
    /// Text the caller hears, and sees as the transcript of what was said.
    Speak {
        text: String,
        voice: Option<String>,
        rate: Option<f64>,
        priority: Option<String>,
    },
    /// A durable artifact: an inline card or a detail screen, the shell's choice.
    Artifact { artifact: Artifact },
    /// A directive to look at an artifact, optionally at a selection inside it (`IDFON-POINT/1`, or `IDFON-SHOW/1` when there is no selector).
    View {
        artifact_id: String,
        selector: Option<ArtifactSelector>,
        blob_ticket: Option<String>,
        note: Option<String>,
    },
    /// A declarative view tree the shell renders from its own component catalog.
    /// Data only: no code, no markup, no scripts.
    JsonRender { title: Option<String>, spec: Value },
    /// A selection inside an artifact the caller should look at.
    Reference { reference: MessageReference },
    /// An envelope this module does not name, kept verbatim.
    Unparsed { header: String, body: String },
}

impl BlockBody {
    /// The short name of this kind, for traces and logs.
    pub fn kind(&self) -> &'static str {
        match self {
            BlockBody::Text { .. } => "text",
            BlockBody::Speak { .. } => "speak",
            BlockBody::Artifact { .. } => "artifact",
            BlockBody::View { .. } => "view",
            BlockBody::JsonRender { .. } => "json_render",
            BlockBody::Reference { .. } => "reference",
            BlockBody::Unparsed { .. } => "unparsed",
        }
    }

    /// The id a producer declared for this block, if the envelope carries one.
    /// A producer that wants to revise a block in place sets it; otherwise
    /// [`Block::id`] is derived from the block's own content.
    fn declared_id(&self) -> Option<String> {
        match self {
            BlockBody::JsonRender { spec, .. } => spec.get("id").and_then(Value::as_str),
            _ => None,
        }
        .map(str::to_owned)
        .filter(|id| !id.trim().is_empty())
    }
}

impl Block {
    pub fn new(body: BlockBody, index: usize) -> Self {
        let id = body
            .declared_id()
            .unwrap_or_else(|| derive_id(&body, index));
        Self { id, body }
    }
}

/// The id of a block that does not declare one: stable for the same content, so
/// a repeated envelope replaces itself rather than appending a duplicate.
fn derive_id(body: &BlockBody, index: usize) -> String {
    let tag = match body {
        BlockBody::Text { .. } => "text".to_string(),
        BlockBody::Speak { .. } => format!("speak-{index}"),
        BlockBody::Artifact { artifact } => format!("artifact-{}", artifact.artifact_id),
        BlockBody::View { artifact_id, .. } => format!("view-{artifact_id}"),
        BlockBody::JsonRender { .. } => format!("render-{index}"),
        BlockBody::Reference { reference } => match reference.refs.first() {
            Some(first) => format!("reference-{}", first.artifact_id),
            None => format!("reference-{index}"),
        },
        // Indexed, not headed: two envelopes of the same kind must not collide.
        BlockBody::Unparsed { header: _, .. } => format!("unparsed-{index}"),
    };
    tag
}

/// Apply a block to a reply's blocks: an id already present is replaced in
/// place, a new id is appended. Order is the producer's.
pub fn upsert(blocks: &mut Vec<Block>, block: Block) {
    match blocks.iter_mut().find(|existing| existing.id == block.id) {
        Some(existing) => *existing = block,
        None => blocks.push(block),
    }
}

/// Parse a wire reply (preamble text plus `IDFON-*/1` envelopes) into blocks, in
/// order. Never fails: what cannot be read is kept verbatim.
pub fn parse(wire: &str) -> Vec<Block> {
    let starts = envelope_starts(wire);
    let mut blocks: Vec<Block> = Vec::new();
    let preamble_end = starts.first().copied().unwrap_or(wire.len());
    let preamble = wire[..preamble_end].trim();
    if !preamble.is_empty() {
        blocks.push(Block::new(
            BlockBody::Text {
                text: preamble.to_string(),
            },
            0,
        ));
    }
    for (index, start) in starts.iter().enumerate() {
        let end = starts.get(index + 1).copied().unwrap_or(wire.len());
        let envelope = wire[*start..end].trim();
        let position = blocks.len();
        upsert(&mut blocks, decode_envelope(envelope, position));
    }
    blocks
}

/// The byte offsets of every envelope header in `wire`, in order.
fn envelope_starts(wire: &str) -> Vec<usize> {
    let mut starts: Vec<usize> = Vec::new();
    for header in ENVELOPE_HEADERS {
        let mut from = 0;
        while let Some(offset) = wire[from..].find(header) {
            let at = from + offset;
            // The app's splitter matches a header anywhere; so this must too,
            // or the two disagree about where a block ends.
            starts.push(at);
            from = at + 1;
        }
    }
    starts.sort_unstable();
    starts
}

fn decode_envelope(envelope: &str, index: usize) -> Block {
    let unparsed = || {
        let (header, body) = split_header(envelope);
        Block::new(
            BlockBody::Unparsed {
                header: header.to_string(),
                body: body.to_string(),
            },
            index,
        )
    };
    if let Some(body) = envelope.strip_prefix("IDFON-SPEAK/1\n") {
        return match decode_speak(body) {
            Some(block) => Block::new(block, index),
            None => unparsed(),
        };
    }
    if envelope.starts_with("IDFON-ARTIFACT/1\n") {
        return match decode_artifact(envelope).and_then(|artifact| {
            artifact
                .validate()
                .map_err(|error| ArtifactError::Malformed(error.to_string()))?;
            Ok(artifact)
        }) {
            Ok(artifact) => Block::new(BlockBody::Artifact { artifact }, index),
            Err(_) => unparsed(),
        };
    }
    if envelope.starts_with("IDFON-REF/1\n") {
        return match decode_reference(envelope) {
            Ok(reference) if reference.validate().is_ok() => {
                Block::new(BlockBody::Reference { reference }, index)
            }
            _ => unparsed(),
        };
    }
    if envelope.starts_with("IDFON-POINT/1\n") || envelope.starts_with("IDFON-SHOW/1\n") {
        return match decode_view(envelope) {
            Some(view) => Block::new(view, index),
            None => unparsed(),
        };
    }
    if let Some(body) = envelope.strip_prefix(RENDER_HEADER) {
        return match decode_render(body) {
            Some(render) => Block::new(render, index),
            None => unparsed(),
        };
    }
    unparsed()
}

fn split_header(envelope: &str) -> (&str, &str) {
    match envelope.find('\n') {
        Some(end) => (&envelope[..end + 1], envelope[end + 1..].trim()),
        None => (envelope, ""),
    }
}

#[derive(Deserialize)]
struct SpeakBody {
    #[serde(default)]
    text: String,
    #[serde(default)]
    voice: Option<String>,
    #[serde(default)]
    rate: Option<f64>,
    #[serde(default)]
    priority: Option<String>,
}

fn decode_speak(body: &str) -> Option<BlockBody> {
    let parsed: SpeakBody = serde_json::from_str(body).ok()?;
    // Spoken text is the one thing a speak block must have: an empty one would
    // play silence and show an empty bubble.
    if parsed.text.trim().is_empty() {
        return None;
    }
    Some(BlockBody::Speak {
        text: parsed.text,
        voice: parsed.voice,
        rate: parsed.rate,
        priority: parsed.priority,
    })
}

#[derive(Deserialize)]
struct ViewBody {
    artifact_id: String,
    #[serde(default)]
    selector: Option<ArtifactSelector>,
    #[serde(default)]
    blob_ticket: Option<String>,
    #[serde(default)]
    note: Option<String>,
}

fn decode_view(envelope: &str) -> Option<BlockBody> {
    let (header, body) = split_header(envelope);
    let parsed: ViewBody = serde_json::from_str(body).ok()?;
    if parsed.artifact_id.trim().is_empty() {
        return None;
    }
    // SHOW carries no selector; POINT does. Which one it was is remembered by
    // whether a selector is present, which is also how the shells render them.
    let _ = header;
    Some(BlockBody::View {
        artifact_id: parsed.artifact_id,
        selector: parsed.selector,
        blob_ticket: parsed.blob_ticket,
        note: parsed.note,
    })
}

#[derive(Deserialize)]
struct RenderBody {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    spec: Value,
}

fn decode_render(body: &str) -> Option<BlockBody> {
    if body.len() > MAX_RENDER_BYTES {
        return None;
    }
    let parsed: RenderBody = serde_json::from_str(body).ok()?;
    if !is_render_spec(&parsed.spec) {
        return None;
    }
    // The title rides the spec so a shell that only passes the spec around (the
    // renderer takes a spec) still has the block's declared id.
    let spec = match (&parsed.id, &parsed.spec) {
        (Some(id), Value::Object(map)) => {
            let mut map = map.clone();
            map.insert("id".to_string(), Value::String(id.clone()));
            Value::Object(map)
        }
        _ => parsed.spec,
    };
    Some(BlockBody::JsonRender {
        title: parsed.title,
        spec,
    })
}

/// The shape a shell must be able to draw: a root element that exists, a
/// bounded set of elements. Which component types exist is the shell's catalog,
/// not this one — an unknown type is dropped by the renderer, not here.
fn is_render_spec(spec: &Value) -> bool {
    let Value::Object(map) = spec else { return false };
    let Some(root) = map.get("root").and_then(Value::as_str) else {
        return false;
    };
    let Value::Object(elements) = map.get("elements").unwrap_or(&Value::Null) else {
        return false;
    };
    !elements.is_empty() && elements.len() <= MAX_RENDER_ELEMENTS && elements.contains_key(root)
}

/// The wire form of a block, so a reply can be rebuilt from its blocks.
pub fn encode(blocks: &[Block]) -> String {
    let mut out = String::new();
    for block in blocks {
        let piece = match &block.body {
            BlockBody::Text { text } => text.trim().to_string(),
            BlockBody::Speak {
                text,
                voice,
                rate,
                priority,
            } => {
                let body = serde_json::json!({
                    "text": text,
                    "voice": voice,
                    "rate": rate,
                    "priority": priority,
                });
                format!("IDFON-SPEAK/1\n{body}")
            }
            BlockBody::Artifact { artifact } => encode_artifact(artifact).unwrap_or_default(),
            BlockBody::Reference { reference } => encode_reference(reference).unwrap_or_default(),
            BlockBody::View {
                artifact_id,
                selector,
                blob_ticket,
                note,
            } => {
                let header = if selector.is_some() {
                    "IDFON-POINT/1"
                } else {
                    "IDFON-SHOW/1"
                };
                let mut body = serde_json::json!({
                    "artifact_id": artifact_id,
                    "blob_ticket": blob_ticket,
                });
                if let (Some(selector), Value::Object(map)) = (selector, &mut body) {
                    map.insert(
                        "selector".to_string(),
                        serde_json::to_value(selector).unwrap_or(Value::Null),
                    );
                    map.insert("note".to_string(), serde_json::to_value(note).unwrap_or(Value::Null));
                }
                format!("{header}\n{body}")
            }
            BlockBody::JsonRender { title, spec } => {
                let body = serde_json::json!({ "title": title, "spec": spec });
                format!("{RENDER_HEADER}{body}")
            }
            BlockBody::Unparsed { header, body } => {
                if body.is_empty() {
                    header.clone()
                } else {
                    format!("{header}{body}")
                }
            }
        };
        if piece.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&piece);
    }
    out
}

/// Build a render block: a spec plus the id it is addressed by. A producer that
/// revises the view later reuses the id, and the shell replaces the block.
pub fn render_block(id: &str, title: Option<&str>, spec: Value) -> Block {
    let spec = match spec {
        Value::Object(mut map) => {
            map.insert("id".to_string(), Value::String(id.to_string()));
            Value::Object(map)
        }
        other => other,
    };
    Block {
        id: id.to_string(),
        body: BlockBody::JsonRender {
            title: title.map(str::to_owned),
            spec,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::artifacts::{ArtifactKind, ArtifactRef};

    fn artifact(id: &str, with_ticket: bool) -> Artifact {
        Artifact {
            artifact_id: id.into(),
            kind: ArtifactKind::Document,
            mime: "text/plain".into(),
            title: format!("{id} title"),
            size_bytes: 12,
            blob_ticket: with_ticket.then(|| format!("ticket-{id}")),
            source_message_id: None,
            conversation: None,
            metadata: Value::Null,
            created_at: "2026-10-11T00:00:00Z".into(),
        }
    }

    fn spec(id: &str) -> Value {
        serde_json::json!({
            "id": id,
            "root": "root",
            "elements": {"root": {"type": "Text", "props": {"text": "hi"}}},
        })
    }

    /// The ordinary reply: something said, then something to look at. Order is
    /// the producer's, and the preamble is a block of its own.
    #[test]
    fn a_reply_parses_into_ordered_blocks() {
        let wire = format!(
            "Here are the two options.\nIDFON-SPEAK/1\n{}\n{}",
            r#"{"text": "I've put both in the chat.", "priority": "normal"}"#,
            encode_artifact(&artifact("a1", true)).unwrap()
        );
        let blocks = parse(&wire);
        assert_eq!(blocks.len(), 3, "preamble + speak + artifact: {blocks:?}");
        assert_eq!(blocks[0].body.kind(), "text");
        assert_eq!(blocks[1].body.kind(), "speak");
        assert_eq!(blocks[2].body.kind(), "artifact");
        match &blocks[1].body {
            BlockBody::Speak { text, priority, .. } => {
                assert_eq!(text, "I've put both in the chat.");
                assert_eq!(priority.as_deref(), Some("normal"));
            }
            other => panic!("not a speak block: {other:?}"),
        }
    }

    /// A render block is data: a root that exists, a bounded element set. The
    /// id in the spec is the block's id, so a revision replaces it.
    #[test]
    fn a_render_block_keeps_its_declared_id() {
        let wire = format!(
            "{}{}",
            RENDER_HEADER,
            serde_json::json!({"title": "Options", "spec": spec("view-1")})
        );
        let blocks = parse(&wire);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].id, "view-1");
        assert_eq!(blocks[0].body.kind(), "json_render");

        // Revisions: the same id replaces, a new id appends.
        let mut blocks = blocks;
        upsert(&mut blocks, render_block("view-1", Some("Options"), spec("view-1")));
        assert_eq!(blocks.len(), 1, "the same id is the same block: {blocks:?}");
        upsert(&mut blocks, render_block("view-2", None, spec("view-2")));
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[1].id, "view-2");
    }

    /// Fail-open, both ways: an envelope this module does not name survives
    /// verbatim, and a block that cannot validate becomes unparsed rather than
    /// reaching a shell as garbage.
    #[test]
    fn unreadable_blocks_are_kept_and_not_drawn() {
        let unknown = "IDFON-FILE/1\nname=notes.txt\nticket=t1";
        let blocks = parse(unknown);
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0].body, BlockBody::Unparsed { header, .. } if header == "IDFON-FILE/1\n"));
        assert!(encode(&blocks).contains("name=notes.txt"), "kept verbatim");

        // An empty speak has nothing to play or show.
        assert!(matches!(
            &parse("IDFON-SPEAK/1\n{\"text\": \"   \"}")[0].body,
            BlockBody::Unparsed { .. }
        ));
        // An artifact with no ticket is not a durable artifact. (Written by
        // hand: the encoder refuses to build one.)
        let no_ticket = format!(
            "IDFON-ARTIFACT/1\n{}",
            serde_json::json!({
                "artifact_id": "a2", "kind": "document", "mime": "text/plain",
                "title": "a2 title", "size_bytes": 12,
                "created_at": "2026-10-11T00:00:00Z",
            })
        );
        assert!(matches!(
            &parse(&no_ticket)[0].body,
            BlockBody::Unparsed { .. }
        ));
        // A render spec must be a spec.
        for bad in [
            serde_json::json!({"spec": {"elements": {}}}),
            serde_json::json!({"spec": {"root": "root", "elements": {}}}),
            serde_json::json!({"spec": {"root": "missing", "elements": {"root": {}}}}),
        ] {
            let wire = format!("{RENDER_HEADER}{bad}");
            assert!(
                matches!(&parse(&wire)[0].body, BlockBody::Unparsed { .. }),
                "not a spec: {bad}"
            );
        }
    }

    /// POINT and SHOW are one kind of directive, told apart by the selector, and
    /// they encode back to the header they came from.
    #[test]
    fn a_view_block_remembers_point_or_show() {
        let point = parse(&format!(
            "IDFON-POINT/1\n{}",
            serde_json::json!({"artifact_id": "a1", "selector": {"type": "whole"}, "blob_ticket": "t1"})
        ));
        assert!(matches!(&point[0].body, BlockBody::View { selector: Some(_), .. }));
        assert!(encode(&point).starts_with("IDFON-POINT/1\n"));

        let show = parse(&format!(
            "IDFON-SHOW/1\n{}",
            serde_json::json!({"artifact_id": "a1", "blob_ticket": "t1"})
        ));
        assert!(matches!(&show[0].body, BlockBody::View { selector: None, .. }));
        assert!(encode(&show).starts_with("IDFON-SHOW/1\n"));
    }

    /// The exact envelope the remote `render` tool emits
    /// (`integrations/eve-idfon/extension/tools/render.ts`). Rust, the tool and
    /// the shells must agree on one shape; this is that shape, pinned.
    #[test]
    fn the_render_tool_wire_parses() {
        let wire = r#"IDFON-RENDER/1
{"title":"Options","spec":{"id":"options","root":"root","elements":{"root":{"type":"Metric","props":{"label":"per month","value":"40"}}}}}"#;
        let blocks = parse(wire);
        assert_eq!(blocks.len(), 1, "{blocks:?}");
        assert_eq!(blocks[0].id, "options");
        match &blocks[0].body {
            BlockBody::JsonRender { title, spec } => {
                assert_eq!(title.as_deref(), Some("Options"));
                assert!(is_render_spec(spec));
                assert_eq!(spec["elements"]["root"]["type"], "Metric");
            }
            other => panic!("not a render block: {other:?}"),
        }
    }

    /// A reply that has been parsed and rebuilt is the same reply: the wire is
    /// not a lossy way to carry blocks.
    #[test]
    fn a_reply_survives_a_round_trip() {
        let wire = format!(
            "Two options.\nIDFON-SPEAK/1\n{}\n{}\n{}",
            r#"{"text": "One is cheaper."}"#,
            encode_artifact(&artifact("a1", true)).unwrap(),
            encode_reference(&MessageReference {
                text: "which one?".into(),
                refs: vec![ArtifactRef {
                    artifact_id: "a1".into(),
                    selector: ArtifactSelector::Whole,
                    blob_ticket: Some("t1".into()),
                    note: None,
                }],
            })
            .unwrap()
        );
        let once = parse(&wire);
        let twice = parse(&encode(&once));
        assert_eq!(once, twice, "parse(encode(parse(w))) is stable");
    }
}
