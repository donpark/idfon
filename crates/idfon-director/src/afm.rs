//! Apple Foundation Models provider for the on-device tier.
//!
//! `fm-rs` runs AFM's tools *inside* the framework and exposes only text, so
//! this provider cannot hand a raw tool call to the loop. It adapts instead:
//!
//! - The model writes what to say (`say`) and optionally picks a tool
//!   (`tool_call`, arguments as a JSON string). The provider turns a non-empty
//!   `say` into a `speak` tool call, so the loop emits `IDFON-SPEAK/1`.
//! - After the loop runs a tool, the provider ends the turn (no second model
//!   pass). Chaining and post-tool narration come later (#36/#38).
//!
//! The loop still owns execution, authority, and trace
//! (`docs/voice-agent-loop-contract.md`).
//!
//! Tier notes: one persistent AFM session per call (the warm-latency lever),
//! and `prewarm` loads the model during call setup. See
//! `docs/voice-agent-harness.md` §5 for measurements.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{json, Value};

use fm_rs::{GenerationOptions, ModelAvailability, Session, SystemLanguageModel};

use crate::turn_input::decode_image;

use yoagent::provider::{
    ProviderError, StreamConfig, StreamEvent, StreamProvider, ToolDefinition,
};
use yoagent::types::{Content, Message, StopReason, Usage};

const MODEL: &str = "apple-foundation-models";
static TOOL_SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Deserialize)]
struct Envelope {
    #[serde(default)]
    say: String,
    #[serde(default)]
    tool_call: Option<ToolCallEnvelope>,
}

#[derive(Debug, Deserialize)]
struct ToolCallEnvelope {
    name: String,
    /// The tool arguments. AFM emits an object; accept a JSON string too.
    #[serde(default)]
    arguments: Value,
}

struct Inner {
    model: SystemLanguageModel,
    session: Option<Session>,
    forwarded: usize,
    prompt_key: String,
}

/// The on-device provider. Cheap to clone; clones share one session.
#[derive(Clone)]
pub struct AfmProvider {
    inner: Arc<Mutex<Inner>>,
    instructions: String,
}

impl AfmProvider {
    pub fn new(instructions: &str, tools: Vec<ToolDefinition>) -> Result<Self, String> {
        let model = SystemLanguageModel::new().map_err(|e| e.to_string())?;
        let availability = model.availability();
        if !matches!(availability, ModelAvailability::Available) {
            return Err(format!("AFM unavailable: {availability:?}"));
        }
        let prompt_key = prompt_key(instructions, &tools);
        let provider = Self {
            inner: Arc::new(Mutex::new(Inner {
                model,
                session: None,
                forwarded: 0,
                prompt_key,
            })),
            instructions: instructions.to_string(),
        };
        provider
            .inner
            .lock()
            .unwrap()
            .ensure(&provider.instructions, &tools);
        Ok(provider)
    }

    /// Load the model and warm the session. Call during call setup.
    pub fn prewarm(&self) {
        let inner = self.inner.lock().unwrap();
        let Some(session) = inner.session.as_ref() else {
            return;
        };
        let opts = GenerationOptions::builder().build();
        let _ = session.respond("Reply with exactly: ok", &opts);
    }
}

impl Inner {
    fn ensure(&mut self, instructions: &str, tools: &[ToolDefinition]) {
        let key = prompt_key(instructions, tools);
        if self.session.is_some() && self.prompt_key == key {
            return;
        }
        let text = format!("{instructions}\n\n{}", tool_protocol(tools));
        self.session = Session::with_instructions_and_tools(&self.model, &text, &[]).ok();
        self.forwarded = 0;
        self.prompt_key = key;
    }
}

#[async_trait]
impl StreamProvider for AfmProvider {
    async fn stream(
        &self,
        config: StreamConfig,
        tx: tokio::sync::mpsc::UnboundedSender<StreamEvent>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<Message, ProviderError> {
        let _ = tx.send(StreamEvent::Start);

        let has_speak = config.tools.iter().any(|t| t.name == "speak");
        let (content, stop_reason, next_forwarded) = {
            let mut inner = self.inner.lock().unwrap();
            inner.ensure(&self.instructions, &config.tools);

            let from = inner.forwarded.min(config.messages.len());
            let mut batch = new_messages(&config.messages, from);
            if batch.is_empty() {
                // Same history resent (retry or compaction): rebuild and replay.
                inner.session = None;
                inner.ensure(&self.instructions, &config.tools);
                batch = new_messages(&config.messages, 0);
            }
            let next_forwarded = config.messages.len();

            if batch.has_user {
                let prompt = batch
                    .text
                    .unwrap_or_else(|| "(continue)".to_string());
                let session = inner
                    .session
                    .as_ref()
                    .ok_or_else(|| ProviderError::Api("AFM session unavailable".into()))?;
                let opts = GenerationOptions::builder().build();
                let envelope = respond(session, &prompt, &batch.images, &config.tools, &opts)?;
                if let Some(call) = envelope
                    .tool_call
                    .as_ref()
                    .and_then(|call| dispatchable(&config.tools, call))
                {
                    let args = parse_arguments(&call.arguments);
                    let id = next_tool_id();
                    (vec![Content::tool_call(id, call.name.clone(), args)], StopReason::ToolUse, next_forwarded)
                } else if has_speak && !envelope.say.trim().is_empty() {
                    let id = next_tool_id();
                    (
                        vec![Content::tool_call(id, "speak", json!({ "text": envelope.say }))],
                        StopReason::ToolUse,
                        next_forwarded,
                    )
                } else if !envelope.say.trim().is_empty() {
                    (
                        vec![Content::Text { text: envelope.say }],
                        StopReason::Stop,
                        next_forwarded,
                    )
                } else {
                    (vec![], StopReason::Stop, next_forwarded)
                }
            } else {
                // Tool-result turn: the loop already ran the tool. End the turn.
                (vec![], StopReason::Stop, next_forwarded)
            }
        };

        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }
        self.inner.lock().unwrap().forwarded = next_forwarded;

        let message = Message::assistant(content, stop_reason, MODEL, "afm", Usage::default());
        for (index, block) in message_content(&message).iter().enumerate() {
            match block {
                Content::Text { text } => {
                    let _ = tx.send(StreamEvent::TextDelta {
                        content_index: index,
                        delta: text.clone(),
                    });
                }
                Content::ToolCall { id, name, .. } => {
                    let _ = tx.send(StreamEvent::ToolCallStart {
                        content_index: index,
                        id: id.clone(),
                        name: name.clone(),
                    });
                    let _ = tx.send(StreamEvent::ToolCallEnd { content_index: index });
                }
                _ => {}
            }
        }
        let _ = tx.send(StreamEvent::Done {
            message: message.clone(),
        });
        Ok(message)
    }
}

fn message_content(message: &Message) -> &[Content] {
    match message {
        Message::Assistant { content, .. } => content,
        _ => &[],
    }
}

fn parse_arguments(value: &Value) -> Value {
    match value {
        Value::String(text) => serde_json::from_str(text).unwrap_or_else(|_| json!({})),
        Value::Null => json!({}),
        other => other.clone(),
    }
}

fn next_tool_id() -> String {
    format!("afm-tool-{}", TOOL_SEQ.fetch_add(1, Ordering::SeqCst))
}

fn prompt_key(instructions: &str, tools: &[ToolDefinition]) -> String {
    format!(
        "{instructions}\u{0}{}",
        serde_json::to_string(tools).unwrap_or_default()
    )
}

fn tool_protocol(tools: &[ToolDefinition]) -> String {
    if tools.is_empty() {
        return "Reply with the spoken text in \"say\".".to_string();
    }
    let mut lines = String::from(
        "Reply with JSON only, matching this shape:\n\
         {\"say\": \"<what to say out loud>\", \"tool_call\": {\"name\": \"<tool>\", \"arguments\": \"<JSON object>\"}}\n\
         Write the spoken words in \"say\". Use \"tool_call\" only to run a tool other than speak.\n\
         Omit \"tool_call\" when no tool is needed. After a \"Tool result:\" message, the tool\n\
         has already run; reply with the final \"say\" and omit \"tool_call\".\n\nTools:\n",
    );
    for tool in tools {
        lines.push_str(&format!(
            "- {}: {} arguments: {}\n",
            tool.name,
            tool.description,
            serde_json::to_string(&tool.parameters).unwrap_or_else(|_| "{}".into())
        ));
    }
    lines
}

fn envelope_schema(tools: &[ToolDefinition]) -> Value {
    let mut properties = json!({
        "say": {
            "type": "string",
            "description": "The spoken reply."
        }
    });
    if !tools.is_empty() {
        let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        // With one tool, reuse its parameter schema so the model fills real fields.
        let arguments = match tools {
            [only] => only.parameters.clone(),
            _ => json!({ "type": "object", "description": "Tool arguments." }),
        };
        properties["tool_call"] = json!({
            "type": "object",
            "properties": {
                "name": { "type": "string", "enum": names },
                "arguments": arguments
            },
            "required": ["name", "arguments"]
        });
    }
    json!({
        "type": "object",
        "properties": properties,
        "required": ["say"]
    })
}

struct Batch {
    text: Option<String>,
    has_user: bool,
    /// Images the new user messages carry, decoded and ready for the model API.
    images: Vec<Vec<u8>>,
}

impl Batch {
    fn is_empty(&self) -> bool {
        self.text.is_none()
    }
}

/// One model call. Images go through the attachment API (Foundation Models 27),
/// which answers in plain text: the envelope is parsed out of it when the model
/// wrote one (the tool protocol is in its instructions), and the whole reply
/// becomes what to say when it did not. A model or OS that cannot take images
/// answers from the prompt instead, where the image is described — an image
/// must never cost the turn.
fn respond(
    session: &Session,
    prompt: &str,
    images: &[Vec<u8>],
    tools: &[ToolDefinition],
    opts: &GenerationOptions,
) -> Result<Envelope, ProviderError> {
    if images.is_empty() {
        return session
            .respond_structured::<Envelope>(prompt, &envelope_schema(tools), opts)
            .map_err(|e| ProviderError::Api(e.to_string()));
    }
    let attachments: Vec<fm_rs::Attachment> = images
        .iter()
        .map(|bytes| fm_rs::Attachment::image_bytes(bytes))
        .collect();
    match session.respond_with_attachments(prompt, &attachments, opts) {
        Ok(response) => Ok(envelope_from_text(response.content())),
        Err(fm_rs::Error::UnsupportedPlatform(_) | fm_rs::Error::UnsupportedCapability(_)) => session
            .respond_structured::<Envelope>(prompt, &envelope_schema(tools), opts)
            .map_err(|e| ProviderError::Api(e.to_string())),
        Err(error) => Err(ProviderError::Api(error.to_string())),
    }
}

/// A tool call the loop can actually run.
///
/// The attachment path is not schema-forced, and the model improvises tool names
/// from what it sees in the prompt — an attachment rendered as `[image] …`
/// produced a call to a tool named `image`. Dispatching that fails the turn, so
/// only tools the loop registered are dispatched; anything else falls back to
/// `say`, which for an app-local agent (its only tool is `speak`) is the answer.
fn dispatchable<'a>(
    tools: &[ToolDefinition],
    call: &'a ToolCallEnvelope,
) -> Option<&'a ToolCallEnvelope> {
    (!call.name.is_empty() && tools.iter().any(|t| t.name == call.name)).then_some(call)
}

/// The reply as an envelope. The model normally writes one; a prose reply (or a
/// JSON object wrapped in prose or a fence) is taken as what to say.
fn envelope_from_text(text: &str) -> Envelope {
    let trimmed = text.trim();
    if let Ok(envelope) = serde_json::from_str::<Envelope>(trimmed) {
        return envelope;
    }
    if let (Some(start), Some(end)) = (trimmed.find('{'), trimmed.rfind('}')) {
        if start < end {
            if let Ok(envelope) = serde_json::from_str::<Envelope>(&trimmed[start..=end]) {
                return envelope;
            }
        }
    }
    Envelope {
        say: trimmed.to_string(),
        tool_call: None,
    }
}

fn new_messages(messages: &[Message], from: usize) -> Batch {
    let mut parts: Vec<String> = Vec::new();
    let mut images: Vec<Vec<u8>> = Vec::new();
    let mut has_user = false;
    for message in messages.iter().skip(from) {
        match message {
            Message::User { content, .. } => {
                has_user = true;
                parts.push(text_of(content));
                images.extend(images_of(content));
            }
            Message::ToolResult { content, .. } => {
                parts.push(format!("Tool result: {}", text_of(content)));
            }
            Message::Assistant { .. } => {}
        }
    }
    parts.retain(|p| !p.trim().is_empty());
    Batch {
        text: if parts.is_empty() {
            None
        } else {
            Some(parts.join("\n\n"))
        },
        has_user,
        images,
    }
}

/// The image parts of a message, decoded. An image the API cannot take (bad
/// mime, oversized, undecodable) is left out here: the prompt already describes
/// it, and dropping it must not fail the turn.
fn images_of(content: &[Content]) -> Vec<Vec<u8>> {
    content
        .iter()
        .filter_map(|c| match c {
            Content::Image { data, mime_type } => decode_image(mime_type, data),
            _ => None,
        })
        .collect()
}

fn text_of(content: &[Content]) -> String {
    content
        .iter()
        .filter_map(|c| match c {
            Content::Text { text } => Some(text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(name: &str) -> ToolDefinition {
        ToolDefinition {
            name: name.into(),
            description: String::new(),
            parameters: json!({}),
        }
    }

    fn call(name: &str) -> ToolCallEnvelope {
        ToolCallEnvelope {
            name: name.into(),
            arguments: json!({}),
        }
    }

    /// The attachment path is not schema-forced, so the model improvises tool
    /// names from the prompt (it called a tool named `image`); only tools the
    /// loop registered may be dispatched, or the turn dies on an unknown tool.
    #[test]
    fn only_registered_tools_are_dispatched() {
        let tools = vec![tool("speak"), tool("voice_forward")];
        assert!(dispatchable(&tools, &call("speak")).is_some());
        assert!(dispatchable(&tools, &call("voice_forward")).is_some());
        assert!(dispatchable(&tools, &call("image")).is_none());
        assert!(dispatchable(&tools, &call("")).is_none());
    }

    /// A prose answer (or JSON wrapped in prose, or in a fenced block) still has
    /// to become what the agent says.
    #[test]
    fn a_reply_becomes_an_envelope() {
        let plain = envelope_from_text("{\"say\": \"hello\", \"tool_call\": null}");
        assert_eq!(plain.say, "hello");
        assert!(plain.tool_call.is_none());

        let fenced = envelope_from_text("Here you go:\n```json\n{\"say\": \"hi\"}\n```");
        assert_eq!(fenced.say, "hi");

        let prose = envelope_from_text("I cannot see any image.");
        assert_eq!(prose.say, "I cannot see any image.");
        assert!(prose.tool_call.is_none());
    }
}
