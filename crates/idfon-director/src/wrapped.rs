//! The wrapped agent as a remote peer (#38).
//!
//! The wrapped agent is a remote idfon peer, not a local child loop, so the
//! director models it as a normal tool (`voice_forward`), not `SubAgentTool`
//! (`docs/voice-agent.md`, `docs/voice-agent-loop-contract.md` §3). The tool
//! calls a [`WrappedAgent`] seam; the shell implements it over the idfon A2A
//! relay, the same path the TypeScript `voice_forward` uses.
//!
//! The tool speaks the reply itself (`IDFON-SPEAK/1`), because the on-device
//! provider ends the turn after a tool result and cannot narrate afterwards.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};

use yoagent::provider::ToolDefinition;
use yoagent::types::{AgentTool, Content, ToolContext, ToolError, ToolResult};

use crate::{speak_envelope, Outbox};

/// The wrapped agent: a remote idfon peer the director forwards a caller turn
/// to. The shell implements this over the idfon transport.
#[async_trait]
pub trait WrappedAgent: Send + Sync {
    /// Send one caller turn and return the wrapped agent's reply.
    ///
    /// `delegation_id` is stable for every retry of the same turn. A send may
    /// have arrived even when the reply was lost, so an implementation must
    /// make the write idempotent: keep the reply for a `delegation_id` it has
    /// already sent, return that stored reply, and do not repeat the work.
    async fn forward(&self, text: &str, delegation_id: &str) -> Result<String, String>;
}

/// Built-in `voice_forward` tool: delegate a turn to the wrapped agent and
/// speak its reply.
pub struct ForwardTool {
    agent: Arc<dyn WrappedAgent>,
    turn: Arc<AtomicU64>,
    outbox: Outbox,
}

impl ForwardTool {
    pub fn new(agent: Arc<dyn WrappedAgent>, turn: Arc<AtomicU64>, outbox: Outbox) -> Self {
        Self {
            agent,
            turn,
            outbox,
        }
    }

    /// The tool definition for a provider prompt (the AFM provider advertises
    /// tools as text).
    pub fn definition() -> ToolDefinition {
        ToolDefinition {
            name: "voice_forward".into(),
            description:
                "Delegate a request to the wrapped agent and speak its reply. Use this for \
                 anything that needs the wrapped agent's knowledge or tools."
                    .into(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "What to ask the wrapped agent." }
                },
                "required": ["text"]
            }),
        }
    }

    fn parameters() -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "What to ask the wrapped agent." }
            },
            "required": ["text"]
        })
    }
}

#[async_trait]
impl AgentTool for ForwardTool {
    fn name(&self) -> &str {
        "voice_forward"
    }
    fn label(&self) -> &str {
        "Forward"
    }
    fn description(&self) -> &str {
        "Delegate a request to the wrapped agent and speak its reply."
    }
    fn parameters_schema(&self) -> Value {
        Self::parameters()
    }
    async fn execute(&self, params: Value, _ctx: ToolContext) -> Result<ToolResult, ToolError> {
        let text = params
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if text.is_empty() {
            return Err(ToolError::InvalidArgs("voice_forward needs text".into()));
        }
        let id = delegation_id(self.turn.load(Ordering::SeqCst), text);
        match self.agent.forward(text, &id).await {
            Ok(reply) => {
                self.outbox.push(speak_envelope(&reply, "normal"));
                Ok(ToolResult {
                    content: vec![Content::Text { text: reply }],
                    details: Value::Null,
                })
            }
            Err(error) => Err(ToolError::Failed(error)),
        }
    }
}

/// A delegation key that is stable across retries of one turn's same request
/// but distinct per turn and per text. The remote side dedupes by this key.
fn delegation_id(turn: u64, text: &str) -> String {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    format!("turn-{turn}-{:016x}", hasher.finish())
}
