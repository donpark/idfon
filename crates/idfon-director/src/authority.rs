//! Authority: the capability grant a director runs under (#37).
//!
//! The director proposes; code and capability grants authorize
//! (`docs/voice-decisions.md`). Every tool call is checked before it runs:
//!
//! - A tool with no grant is denied. The check is code, so it fails closed.
//! - A budget-capped session denies once its call budget is spent.
//! - An optional decider may propose a veto. A failing decider allows the
//!   call (fail-open); no call depends on a decider.
//!
//! Refusals are recorded and surfaced in the turn trace by [`Director`](crate::Director).

use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use yoagent::decision::{DecisionModel, Question};
use yoagent::extension::{ExtensionError, RunContext};
use yoagent::types::{ToolCallRequest, ToolDecision};
use yoagent::{Extension, RunHooks};

/// A tool call the authority refused, with the reason.
#[derive(Clone, Debug)]
pub struct Refusal {
    pub tool: String,
    pub reason: String,
}

#[derive(Default)]
struct Ledger {
    used: u32,
    refusals: Vec<Refusal>,
}

#[derive(Clone)]
struct Decider {
    model: DecisionModel,
    deny_at_or_above: f64,
}

/// A capability grant for one director session.
///
/// `grant` lists the tools the grant permits; the budget caps how many tool
/// calls the session may run. Clones share one ledger, so a delegate spends
/// from the same budget.
#[derive(Clone)]
pub struct Authority {
    allow: Arc<Vec<String>>,
    cap: Option<u32>,
    ledger: Arc<Mutex<Ledger>>,
    decider: Option<Decider>,
}

impl Authority {
    /// A grant allowing exactly `tools`, with no budget cap.
    pub fn grant(tools: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            allow: Arc::new(tools.into_iter().map(Into::into).collect()),
            cap: None,
            ledger: Arc::new(Mutex::new(Ledger::default())),
            decider: None,
        }
    }

    /// Cap how many tool calls this session (and its delegates) may run.
    pub fn with_budget(mut self, calls: u32) -> Self {
        self.cap = Some(calls);
        self
    }

    /// Add a decider that proposes a veto. The call is denied when the
    /// decider's probability is at least `deny_at_or_above`. A failing
    /// decider allows the call (fail-open); the grant still applies.
    pub fn with_decider(mut self, model: DecisionModel, deny_at_or_above: f64) -> Self {
        self.decider = Some(Decider {
            model,
            deny_at_or_above,
        });
        self
    }

    /// A child grant for a sub-agent: same tools and ledger, budget clamped to
    /// what the parent has left. A child cannot raise its parent's budget.
    pub fn delegate(&self, calls: u32) -> Self {
        let remaining = self.remaining().unwrap_or(calls);
        Self {
            allow: Arc::clone(&self.allow),
            cap: Some(calls.min(remaining)),
            ledger: Arc::clone(&self.ledger),
            decider: self.decider.clone(),
        }
    }

    /// Tool calls left under the cap, or `None` when uncapped.
    pub fn remaining(&self) -> Option<u32> {
        self.cap
            .map(|cap| cap.saturating_sub(self.ledger.lock().unwrap().used))
    }

    /// How many calls the grant has authorized so far.
    pub fn used(&self) -> u32 {
        self.ledger.lock().unwrap().used
    }

    /// Take the refusals recorded since the last call.
    pub fn drain_refusals(&self) -> Vec<Refusal> {
        std::mem::take(&mut self.ledger.lock().unwrap().refusals)
    }

    fn refuse(&self, tool: &str, reason: impl Into<String>) -> ToolDecision {
        let reason = reason.into();
        self.ledger.lock().unwrap().refusals.push(Refusal {
            tool: tool.to_string(),
            reason: reason.clone(),
        });
        ToolDecision::Deny(reason)
    }

    /// Judge one call: grant, budget, then the optional decider.
    async fn judge(&self, call: &ToolCallRequest<'_>) -> ToolDecision {
        if !self.allow.iter().any(|t| t == call.tool_name) {
            return self.refuse(
                call.tool_name,
                format!("no capability grant for `{}`", call.tool_name),
            );
        }
        let exhausted = {
            let mut ledger = self.ledger.lock().unwrap();
            let full = self.cap.is_some_and(|cap| ledger.used >= cap);
            if !full {
                ledger.used += 1;
            }
            full
        };
        if exhausted {
            return self.refuse(call.tool_name, "tool-call budget exhausted");
        }
        if let Some(decider) = &self.decider {
            if let Some(p) = veto_probability(decider, call).await {
                if p >= decider.deny_at_or_above {
                    return self.refuse(call.tool_name, format!("decider veto (p={p:.2})"));
                }
            }
        }
        ToolDecision::Allow
    }
}

/// The decider's probability that the call should be vetoed. `None` on any
/// decider failure — the caller then allows (fail-open).
async fn veto_probability(decider: &Decider, call: &ToolCallRequest<'_>) -> Option<f64> {
    let state = json!({
        "user_request": call.user_request(),
        "tool_call": { "tool": call.tool_name, "arguments": call.args },
    });
    let question = Question::noul(Value::String(
        "Is `tool_call` outside what `user_request` authorizes, or destructive?".into(),
    ));
    let evaluation = decider
        .model
        .evaluate(state, vec![("veto".to_string(), question)])
        .await
        .ok()?;
    evaluation.p_true("veto")
}

#[async_trait::async_trait]
impl Extension for Authority {
    fn name(&self) -> &str {
        "idfon-authority"
    }

    async fn start_run(&self, _run: &RunContext<'_>) -> Result<Box<dyn RunHooks>, ExtensionError> {
        Ok(Box::new(self.clone()))
    }
}

#[async_trait::async_trait]
impl RunHooks for Authority {
    async fn before_tool(&self, call: &ToolCallRequest<'_>) -> ToolDecision {
        self.judge(call).await
    }
}
