//! idfon director: the thin voice-agent loop boundary.
//!
//! This crate owns the interface the idfon apps and agents use — turns, tools,
//! and trace — and delegates the loop itself to `yoagent` (decision #31).
//! Keeping the boundary idfon-owned makes the harness swappable.
//!
//! The portable contract (prompt sections, tool schemas, trace record) is
//! `docs/voice-agent-loop-contract.md`.
//!
//! Tier seam: a [`yoagent::provider::StreamProvider`]. On-device that is
//! Apple Foundation Models (`fm-rs`, #34); remotely a hosted provider. The
//! scaffold in [`Director::mock`] is for tests and the FFI probe only.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use yoagent::agent::Agent;
use yoagent::decision::{DecisionModel, InputGuard, ToolGate};
use yoagent::provider::{ModelConfig, StreamProvider, ToolDefinition};
use yoagent::types::{AgentTool, Content, ToolContext, ToolError, ToolResult};
use yoagent::{AgentEvent, StreamDelta};

use crate::authority::Authority;

/// A session outbox of `IDFON-*/1` envelopes. Tools push; the app drains.
///
/// This mirrors the Eve extension outbox: the model emits envelopes through
/// tools, so it never has to echo them in its reply.
#[derive(Clone, Default)]
pub struct Outbox(Arc<Mutex<Vec<String>>>);

impl Outbox {
    pub fn push(&self, envelope: impl Into<String>) {
        self.0.lock().unwrap().push(envelope.into());
    }

    pub fn drain(&self) -> Vec<String> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}

/// Built-in `speak` tool: emits `IDFON-SPEAK/1`.
pub struct SpeakTool {
    outbox: Outbox,
}

impl SpeakTool {
    pub fn new(outbox: Outbox) -> Self {
        Self { outbox }
    }

    /// The tool definition for a provider prompt. The AFM provider advertises
    /// tools as text, so it needs the same schema the loop uses.
    pub fn definition() -> ToolDefinition {
        ToolDefinition {
            name: "speak".into(),
            description:
                "Speak a short response aloud. Long text and visuals belong in an artifact.".into(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "The spoken response, short and conversational." },
                    "priority": { "type": "string", "enum": ["normal", "interrupt"] }
                },
                "required": ["text"]
            }),
        }
    }
}

#[async_trait]
impl AgentTool for SpeakTool {
    fn name(&self) -> &str {
        "speak"
    }
    fn label(&self) -> &str {
        "Speak"
    }
    fn description(&self) -> &str {
        "Speak a short response aloud. Long text and visuals belong in an artifact."
    }
    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "The spoken response, short and conversational." },
                "priority": { "type": "string", "enum": ["normal", "interrupt"] }
            },
            "required": ["text"]
        })
    }
    async fn execute(&self, params: Value, _ctx: ToolContext) -> Result<ToolResult, ToolError> {
        let text = params.get("text").and_then(Value::as_str).unwrap_or("");
        if text.is_empty() {
            return Err(ToolError::InvalidArgs("speak needs text".into()));
        }
        let priority = params
            .get("priority")
            .and_then(Value::as_str)
            .unwrap_or("normal");
        let body = json!({
            "text": text,
            "voice": null,
            "language": null,
            "rate": null,
            "priority": priority,
            "correlation_id": null
        });
        self.outbox.push(format!("IDFON-SPEAK/1\n{body}"));
        Ok(ToolResult {
            content: vec![Content::Text {
                text: "spoken".into(),
            }],
            details: Value::Null,
        })
    }
}

/// One traced step in a turn.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TraceStep {
    pub kind: String,
    pub name: Option<String>,
    pub latency_ms: u128,
    /// Why a step was refused, or other step detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// The result of one turn: envelopes emitted, spoken text seen, trace steps.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TurnResult {
    pub envelopes: Vec<String>,
    pub trace: Vec<TraceStep>,
    /// Wall-clock time for the whole turn.
    pub elapsed_ms: u64,
}

impl TurnResult {
    /// Compose the wire reply: the preamble text, then the envelopes in
    /// tool-call order. This mirrors the `eve-idfon` outbox append
    /// (`event.message + "\n" + envelopes.join("\n")`), so the app parses the
    /// same `IDFON-*/1` blocks it already knows (`docs/voice-multimodal.md`).
    pub fn wire_text(&self, preamble: &str) -> String {
        if self.envelopes.is_empty() {
            return preamble.to_string();
        }
        if preamble.trim().is_empty() {
            return self.envelopes.join("\n");
        }
        format!("{preamble}\n{}", self.envelopes.join("\n"))
    }
}

/// Decision wiring for a director: the `decide` tool model, and optional gate
/// and guard. All fields are optional; the `decide` tool needs `model`.
#[derive(Default)]
pub struct DecisionOptions {
    pub model: Option<DecisionModel>,
    pub gate: Option<ToolGate>,
    pub guard: Option<InputGuard>,
}

/// The director: one persistent loop for one session (one call).
///
/// Owns a current-thread runtime, so the public API is synchronous and the FFI
/// is thin. Do not call `turn` from inside another Tokio runtime on the same
/// thread.
pub struct Director {
    rt: tokio::runtime::Runtime,
    agent: Agent,
    outbox: Outbox,
    prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    authority: Option<Authority>,
}

impl Director {
    /// Build a director on a provider. The provider is the tier seam.
    pub fn with_provider(provider: impl StreamProvider + 'static, instructions: &str) -> Self {
        Self::build(provider, instructions, None, None, None)
    }

    /// Build a director with an optional prewarm hook (load + warm the session).
    pub fn with_provider_and_prewarm(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::build(provider, instructions, None, None, prewarm)
    }

    /// Build a director with decision models: a `decide` tool, and optional tool
    /// gate and input guard (`docs/voice-decisions.md`).
    pub fn with_decision(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        decision: DecisionOptions,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::build(provider, instructions, Some(decision), None, prewarm)
    }

    /// Build a director whose every tool call is checked against a capability
    /// grant (fail-closed), an optional budget, and an optional advisory
    /// decider that fails open (`docs/voice-decisions.md`). An optional
    /// [`DecisionOptions`] adds the `decide` tool and its gate/guard.
    pub fn with_authority(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        authority: Authority,
        decision: Option<DecisionOptions>,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::build(provider, instructions, decision, Some(authority), prewarm)
    }

    fn build(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        decision: Option<DecisionOptions>,
        authority: Option<Authority>,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        let outbox = Outbox::default();
        let mut tools: Vec<Box<dyn AgentTool>> = vec![Box::new(SpeakTool::new(outbox.clone()))];
        let mut agent =
            Agent::from_provider(provider, ModelConfig::mock()).with_system_prompt(instructions);
        if let Some(options) = decision {
            if let Some(model) = options.model {
                tools.push(Box::new(crate::decide::DecideTool::new(model.clone())));
            }
            if let Some(gate) = options.gate {
                agent = agent.with_tool_gate(gate);
            }
            if let Some(guard) = options.guard {
                agent = agent.with_input_guard(guard);
            }
        }
        // Tree extension: child loops inherit the grant and cannot remove it.
        if let Some(authority) = &authority {
            agent = agent.with_tree_extension(authority.clone());
        }
        agent = agent.with_tools(tools);
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build current-thread runtime");
        Self {
            rt,
            agent,
            outbox,
            prewarm,
            authority,
        }
    }

    /// Prewarm the model before the first turn (load + warm session).
    ///
    /// The mock scaffold does nothing. The AFM provider loads the model and
    /// warms its persistent session here, during call setup.
    pub fn prewarm(&self) {
        if let Some(prewarm) = &self.prewarm {
            prewarm();
        }
    }

    /// Run one turn to completion and return the emitted envelopes and trace.
    pub fn turn(&mut self, text: &str) -> TurnResult {
        let started = Instant::now();
        let mut trace: Vec<TraceStep> = Vec::new();
        let rt = &self.rt;
        rt.block_on(run_turn(&mut self.agent, text, &mut trace));
        if let Some(authority) = &self.authority {
            for refusal in authority.drain_refusals() {
                trace.push(TraceStep {
                    kind: "denied".into(),
                    name: Some(refusal.tool),
                    latency_ms: 0,
                    detail: Some(refusal.reason),
                });
            }
        }
        TurnResult {
            envelopes: self.outbox.drain(),
            trace,
            elapsed_ms: started.elapsed().as_millis() as u64,
        }
    }
}

async fn run_turn(agent: &mut Agent, text: &str, trace: &mut Vec<TraceStep>) {
    let mut tool_start: Option<Instant> = None;
    let mut rx = agent.prompt(text).await;
    while let Some(event) = rx.recv().await {
        match event {
            AgentEvent::ToolExecutionStart { tool_name, .. } => {
                tool_start = Some(Instant::now());
                trace.push(TraceStep {
                    kind: "tool_call".into(),
                    name: Some(tool_name),
                    latency_ms: 0,
                    detail: None,
                });
            }
            AgentEvent::ToolExecutionEnd { tool_name, .. } => {
                let latency_ms = tool_start.take().map_or(0, |t| t.elapsed().as_millis());
                trace.push(TraceStep {
                    kind: "tool_result".into(),
                    name: Some(tool_name),
                    latency_ms,
                    detail: None,
                });
            }
            AgentEvent::MessageUpdate {
                delta: StreamDelta::Text { .. },
                ..
            } => {}
            AgentEvent::AgentEnd { .. } => {
                trace.push(TraceStep {
                    kind: "model".into(),
                    name: None,
                    latency_ms: 0,
                    detail: None,
                });
            }
            _ => {}
        }
    }
}

/// Scaffold provider for tests and the FFI probe: one `speak` call, then done.
pub fn mock_director(instructions: &str) -> Director {
    use yoagent::provider::mock::{MockResponse, MockToolCall};
    let provider = yoagent::provider::MockProvider::new(vec![
        MockResponse::ToolCalls(vec![MockToolCall {
            name: "speak".into(),
            arguments: json!({ "text": "hello from the director scaffold" }),
            provider_metadata: None,
        }]),
        MockResponse::Text("done".into()),
    ]);
    Director::with_provider(provider, instructions)
}

#[cfg(feature = "afm")]
impl Director {
    /// Build the on-device director on Apple Foundation Models.
    ///
    /// Fails when AFM is unavailable (below the OS floor, or Apple Intelligence
    /// off). The caller falls back to the remote tier.
    pub fn afm(instructions: &str) -> Result<Self, String> {
        let tools = vec![SpeakTool::definition()];
        let provider = crate::afm::AfmProvider::new(instructions, tools)?;
        let warm = provider.clone();
        Ok(Self::with_provider_and_prewarm(
            provider,
            instructions,
            Some(Box::new(move || warm.prewarm())),
        ))
    }
}

#[cfg(feature = "afm")]
pub mod afm;

pub mod authority;

pub mod decide;

pub mod ffi;
