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

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use yoagent::agent::Agent;
use yoagent::decision::{DecisionModel, InputGuard, ToolGate};
use yoagent::provider::{ModelConfig, StreamProvider, ToolDefinition};
use yoagent::types::{AgentMessage, AgentTool, Content, Message, ToolContext, ToolError, ToolResult};
use yoagent::{AgentEvent, StreamDelta};

use crate::authority::Authority;
use crate::trace::{
    content_hash, sections, short_hash, PromptRef, Redaction, ToolsRef, TraceInfo, TraceInput,
    TraceOutcome, TraceOutput, TraceRecord, SCHEMA_VERSION,
};
use crate::turn_input::{ReadReferenceTool, ReferenceResolver, TurnInput};
use crate::wrapped::{ForwardTool, WrappedAgent};

pub use crate::trace::TraceStep;

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

/// The `IDFON-SPEAK/1` envelope for `text`. Shared by `speak` and
/// `voice_forward`.
pub(crate) fn speak_envelope(text: &str, priority: &str) -> String {
    let body = json!({
        "text": text,
        "voice": null,
        "language": null,
        "rate": null,
        "priority": priority,
        "correlation_id": null
    });
    format!("IDFON-SPEAK/1\n{body}")
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
        self.outbox.push(speak_envelope(text, priority));
        Ok(ToolResult {
            content: vec![Content::Text {
                text: "spoken".into(),
            }],
            details: Value::Null,
        })
    }
}

/// The result of one turn: envelopes emitted and the full trace record (#40).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TurnResult {
    pub envelopes: Vec<String>,
    /// The contract trace record (`docs/voice-agent-loop-contract.md` §4).
    pub record: TraceRecord,
    /// Wall-clock time for the whole turn.
    pub elapsed_ms: u64,
}

impl TurnResult {
    /// The traced steps of the turn.
    pub fn trace(&self) -> &[TraceStep] {
        &self.record.steps
    }

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

/// Everything a director can be built with. All fields are optional.
#[derive(Default)]
pub struct DirectorOptions {
    /// The `decide` tool plus its gate and guard (`docs/voice-decisions.md`).
    pub decision: DecisionOptions,
    /// The capability grant and budget for every tool call (#37).
    pub authority: Option<Authority>,
    /// The wrapped remote agent, exposed as `voice_forward` (#38).
    pub wrapped: Option<Arc<dyn WrappedAgent>>,
    /// Resolves artifact references for `read_reference` (#39).
    pub resolver: Option<Arc<dyn ReferenceResolver>>,
    /// The tier/provider/model recorded in the trace (#40).
    pub trace: TraceInfo,
    /// The trace privacy policy (#40).
    pub redaction: Redaction,
    /// Loads and warms the model at call setup.
    pub prewarm: Option<Box<dyn Fn() + Send + Sync>>,
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
    /// Monotonic turn counter; a delegating tool keys its idempotency on it,
    /// and the trace records it as the step index.
    turn: Arc<AtomicU64>,
    /// The caller's exact words for the current turn, forwarded verbatim by
    /// `voice_forward`.
    turn_text: Arc<Mutex<String>>,
    prompt: PromptRef,
    tools: ToolsRef,
    trace_info: TraceInfo,
    redaction: Redaction,
}

/// The tool definitions for a set of options. Used to advertise the tools to a
/// provider that needs them up front (AFM).
#[cfg(feature = "afm")]
fn option_definitions(options: &DirectorOptions) -> Vec<ToolDefinition> {
    let mut definitions = vec![SpeakTool::definition()];
    if options.wrapped.is_some() {
        definitions.push(ForwardTool::definition());
    }
    if options.resolver.is_some() {
        definitions.push(ReadReferenceTool::definition());
    }
    if options.decision.model.is_some() {
        definitions.push(crate::decide::DecideTool::definition());
    }
    definitions
}

impl Director {
    /// Build a director from [`DirectorOptions`]. The provider is the tier seam.
    pub fn new(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        options: DirectorOptions,
    ) -> Self {
        Self::assemble(provider, instructions, options)
    }

    fn assemble(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        options: DirectorOptions,
    ) -> Self {
        let DirectorOptions {
            decision,
            authority,
            wrapped,
            resolver,
            trace: trace_info,
            redaction,
            prewarm,
        } = options;
        let outbox = Outbox::default();
        let turn = Arc::new(AtomicU64::new(0));
        let turn_text = Arc::new(Mutex::new(String::new()));
        let mut tools: Vec<Box<dyn AgentTool>> = vec![Box::new(SpeakTool::new(outbox.clone()))];
        if let Some(wrapped) = wrapped {
            tools.push(Box::new(ForwardTool::new(
                wrapped,
                Arc::clone(&turn),
                Arc::clone(&turn_text),
                outbox.clone(),
            )));
        }
        if let Some(resolver) = resolver {
            tools.push(Box::new(ReadReferenceTool::new(resolver)));
        }
        let mut agent =
            Agent::from_provider(provider, ModelConfig::mock()).with_system_prompt(instructions);
        if let Some(model) = decision.model {
            tools.push(Box::new(crate::decide::DecideTool::new(model.clone())));
        }
        if let Some(gate) = decision.gate {
            agent = agent.with_tool_gate(gate);
        }
        if let Some(guard) = decision.guard {
            agent = agent.with_input_guard(guard);
        }
        // Tree extension: child loops inherit the grant and cannot remove it.
        if let Some(authority) = &authority {
            agent = agent.with_tree_extension(authority.clone());
        }
        // Version the prompt and the tool schemas by content, so a trace names
        // the exact pair it ran against (#40).
        let prompt = PromptRef {
            id: "idfon-director".into(),
            version: content_hash(instructions.as_bytes()),
            sections: sections(instructions),
        };
        let mut schemas: Vec<Value> = tools
            .iter()
            .map(|tool| json!({ "name": tool.name(), "parameters": tool.parameters_schema() }))
            .collect();
        schemas.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
        let tools_ref = ToolsRef {
            schema_version: SCHEMA_VERSION.into(),
            hash: content_hash(&serde_json::to_vec(&schemas).unwrap_or_default()),
        };
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
            turn,
            turn_text,
            prompt,
            tools: tools_ref,
            trace_info,
            redaction,
        }
    }

    /// Build a director on a provider. The provider is the tier seam.
    pub fn with_provider(provider: impl StreamProvider + 'static, instructions: &str) -> Self {
        Self::new(provider, instructions, DirectorOptions::default())
    }

    /// Build a director with an optional prewarm hook (load + warm the session).
    pub fn with_provider_and_prewarm(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::new(
            provider,
            instructions,
            DirectorOptions {
                prewarm,
                ..Default::default()
            },
        )
    }

    /// Build a director with decision models: a `decide` tool, and optional tool
    /// gate and input guard (`docs/voice-decisions.md`).
    pub fn with_decision(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        decision: DecisionOptions,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::new(
            provider,
            instructions,
            DirectorOptions {
                decision,
                prewarm,
                ..Default::default()
            },
        )
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
        Self::new(
            provider,
            instructions,
            DirectorOptions {
                decision: decision.unwrap_or_default(),
                authority: Some(authority),
                prewarm,
                ..Default::default()
            },
        )
    }

    /// Build a director that can delegate to a wrapped remote agent
    /// (`voice_forward`, #38). The wrapped agent is a normal tool over the
    /// [`WrappedAgent`] seam, not a local child loop.
    pub fn with_wrapped_agent(
        provider: impl StreamProvider + 'static,
        instructions: &str,
        wrapped: Arc<dyn WrappedAgent>,
        decision: Option<DecisionOptions>,
        authority: Option<Authority>,
        prewarm: Option<Box<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self::new(
            provider,
            instructions,
            DirectorOptions {
                decision: decision.unwrap_or_default(),
                authority,
                wrapped: Some(wrapped),
                prewarm,
                ..Default::default()
            },
        )
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

    /// Run one typed turn to completion and return the emitted envelopes and
    /// the full trace record.
    pub fn turn(&mut self, text: &str) -> TurnResult {
        let input = TraceInput {
            text: text.to_string(),
            parts: vec!["text".into()],
            refs: Vec::new(),
        };
        self.run(text, input)
    }

    /// Run one turn from its parts: text, references, and attachments, joined
    /// into one question (`docs/voice-multimodal.md`). A camera frame is
    /// included only under the `camera` grant; an image the model API accepts
    /// travels as a content part beside the prompt.
    pub fn turn_input(&mut self, input: &TurnInput) -> TurnResult {
        let camera = self.authority.as_ref().is_some_and(|a| a.permits("camera"));
        self.run_content(input.content(camera), input.trace_input())
    }

    fn run(&mut self, prompt: &str, input: TraceInput) -> TurnResult {
        self.run_content(
            vec![Content::Text {
                text: prompt.to_string(),
            }],
            input,
        )
    }

    fn run_content(&mut self, content: Vec<Content>, input: TraceInput) -> TurnResult {
        let started = Instant::now();
        let step = self.turn.fetch_add(1, Ordering::SeqCst) as u32;
        if let Ok(mut current) = self.turn_text.lock() {
            *current = input.text.clone();
        }
        let mut steps: Vec<TraceStep> = Vec::new();
        let ended = self
            .rt
            .block_on(run_turn(&mut self.agent, content, &mut steps));
        if let Some(authority) = &self.authority {
            for refusal in authority.drain_refusals() {
                steps.push(TraceStep {
                    kind: "denied".into(),
                    name: Some(refusal.tool),
                    latency_ms: 0,
                    args: None,
                    ok: None,
                    detail: Some(refusal.reason),
                });
            }
        }
        let envelopes = self.outbox.drain();
        let output = TraceOutput {
            speak: speak_output(&envelopes),
            artifacts: Vec::new(),
        };
        let turn_id = format!(
            "turn-{step}-{}",
            short_hash(&format!(
                "{}|{}|{}",
                self.prompt.version, self.tools.hash, input.text
            ))
        );
        let trace_id = content_hash(
            format!(
                "{}|{}|{}|{}",
                self.prompt.version, self.tools.hash, turn_id, input.text
            )
            .as_bytes(),
        );
        let record = TraceRecord {
            trace_id,
            parent_id: None,
            turn_id,
            step,
            ts: crate::trace::rfc3339(SystemTime::now()),
            tier: self.trace_info.tier.clone(),
            provider: self.trace_info.provider.clone(),
            model: self.trace_info.model.clone(),
            prompt: self.prompt.clone(),
            tools: self.tools.clone(),
            input,
            steps,
            output,
            outcome: TraceOutcome {
                status: if ended { "ok" } else { "error" }.into(),
                reason: None,
            },
            redaction: self.redaction.clone(),
            labels: BTreeMap::new(),
        };
        TurnResult {
            envelopes,
            record,
            elapsed_ms: started.elapsed().as_millis() as u64,
        }
    }
}

/// The text of the first `IDFON-SPEAK/1` envelope, for the trace output.
fn speak_output(envelopes: &[String]) -> Option<String> {
    envelopes.iter().find_map(|envelope| {
        let body = envelope.strip_prefix("IDFON-SPEAK/1\n")?;
        let value: Value = serde_json::from_str(body).ok()?;
        value.get("text")?.as_str().map(str::to_string)
    })
}

/// Run the loop and record one step per event. Returns whether the turn ended
/// normally (`AgentEnd`), for the trace outcome.
async fn run_turn(agent: &mut Agent, content: Vec<Content>, trace: &mut Vec<TraceStep>) -> bool {
    let mut tool_start: Option<Instant> = None;
    let mut ended = false;
    // A literal timestamp: the loop does not use message times, and yoagent's
    // own tests construct messages the same way.
    let message = AgentMessage::Llm(Message::User {
        content,
        timestamp: 0,
    });
    let mut rx = agent.prompt_messages(vec![message]).await;
    while let Some(event) = rx.recv().await {
        match event {
            AgentEvent::ToolExecutionStart {
                tool_name, args, ..
            } => {
                tool_start = Some(Instant::now());
                trace.push(TraceStep {
                    kind: "tool_call".into(),
                    name: Some(tool_name),
                    latency_ms: 0,
                    args: Some(args),
                    ok: None,
                    detail: None,
                });
            }
            AgentEvent::ToolExecutionEnd {
                tool_name,
                is_error,
                ..
            } => {
                let latency_ms = tool_start.take().map_or(0, |t| t.elapsed().as_millis());
                trace.push(TraceStep {
                    kind: "tool_result".into(),
                    name: Some(tool_name),
                    latency_ms,
                    args: None,
                    ok: Some(!is_error),
                    detail: None,
                });
            }
            AgentEvent::MessageUpdate {
                delta: StreamDelta::Text { .. },
                ..
            } => {}
            AgentEvent::AgentEnd { .. } => {
                ended = true;
                trace.push(TraceStep {
                    kind: "model".into(),
                    name: None,
                    latency_ms: 0,
                    args: None,
                    ok: None,
                    detail: None,
                });
            }
            _ => {}
        }
    }
    ended
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
        Self::afm_with_options(instructions, DirectorOptions::default())
    }

    /// Build the on-device AFM director with policy options (authority, trace,
    /// tools). The provider advertises exactly `option_definitions(options)`.
    pub fn afm_with_options(
        instructions: &str,
        mut options: DirectorOptions,
    ) -> Result<Self, String> {
        let provider = crate::afm::AfmProvider::new(instructions, option_definitions(&options))?;
        let warm = provider.clone();
        options.prewarm = Some(Box::new(move || warm.prewarm()));
        Ok(Self::assemble(provider, instructions, options))
    }
}

#[cfg(feature = "afm")]
pub mod afm;

pub mod authority;

pub mod decide;

pub mod ffi;

pub mod trace;

pub mod turn_input;

pub mod wrapped;
