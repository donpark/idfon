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
use std::ffi::{CStr, CString};
use std::hash::{Hash, Hasher};
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

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

/// A host callback that forwards one turn and returns the reply.
///
/// On success it sets `out_reply` to a heap string the host owns and returns 0;
/// `free_reply` releases it. A non-zero return is an error.
///
/// # Safety
/// `ctx`, `text`, and `delegation_id` are valid for the call. The reply pointer
/// must come from the host allocator that `free_reply` releases.
pub type ForwardFn = unsafe extern "C" fn(
    ctx: *mut c_void,
    text: *const c_char,
    delegation_id: *const c_char,
    out_reply: *mut *mut c_char,
) -> i32;

/// Releases a reply string the [`ForwardFn`] returned.
pub type FreeReplyFn = unsafe extern "C" fn(*mut c_char);

/// A raw host pointer, shared with the loop thread. The host guarantees it is
/// safe to use from the director's background thread.
struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// A [`WrappedAgent`] over host callbacks (the Swift app forwards to the called
/// idfon peer). The callback blocks the loop thread while the host waits for the
/// reply, which is why the director runs off the main thread.
pub struct CallbackWrapped {
    ctx: Ctx,
    forward: ForwardFn,
    free: FreeReplyFn,
}

impl CallbackWrapped {
    /// # Safety
    /// `ctx` must stay valid for the director's life, `forward` must be safe to
    /// call from the loop thread, and `free` must accept the pointer `forward`
    /// returns.
    pub unsafe fn new(ctx: *mut c_void, forward: ForwardFn, free: FreeReplyFn) -> Self {
        Self {
            ctx: Ctx(ctx),
            forward,
            free,
        }
    }
}

#[async_trait]
impl WrappedAgent for CallbackWrapped {
    async fn forward(&self, text: &str, delegation_id: &str) -> Result<String, String> {
        let text = CString::new(text).map_err(|_| "text contains NUL".to_string())?;
        let id = CString::new(delegation_id).map_err(|_| "id contains NUL".to_string())?;
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = unsafe { (self.forward)(self.ctx.0, text.as_ptr(), id.as_ptr(), &mut out) };
        if code != 0 || out.is_null() {
            return Err(format!("wrapped forward failed (code {code})"));
        }
        let reply = unsafe { CStr::from_ptr(out) }.to_string_lossy().into_owned();
        unsafe { (self.free)(out) };
        Ok(reply)
    }
}

/// Built-in `voice_forward` tool: delegate a turn to the wrapped agent and
/// speak its reply.
pub struct ForwardTool {
    agent: Arc<dyn WrappedAgent>,
    turn: Arc<AtomicU64>,
    /// The caller's exact words for the current turn. Forwarded verbatim, so
    /// the on-device model cannot paraphrase the question away.
    turn_text: Arc<Mutex<String>>,
    outbox: Outbox,
}

impl ForwardTool {
    pub fn new(
        agent: Arc<dyn WrappedAgent>,
        turn: Arc<AtomicU64>,
        turn_text: Arc<Mutex<String>>,
        outbox: Outbox,
    ) -> Self {
        Self {
            agent,
            turn,
            turn_text,
            outbox,
        }
    }

    /// The tool definition for a provider prompt (the AFM provider advertises
    /// tools as text).
    pub fn definition() -> ToolDefinition {
        ToolDefinition {
            name: "voice_forward".into(),
            description:
                "Delegate the caller's turn to the wrapped agent and speak its reply. Use this \
                 for anything that needs the wrapped agent's knowledge or tools. The caller's \
                 exact words are forwarded; the `text` argument is only a fallback."
                    .into(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "Fallback only: the caller's exact words are forwarded when known." }
                }
            }),
        }
    }

    fn parameters() -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "Fallback only: the caller's exact words are forwarded when known." }
            }
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
        "Delegate the caller's turn to the wrapped agent and speak its reply."
    }
    fn parameters_schema(&self) -> Value {
        Self::parameters()
    }
    async fn execute(&self, params: Value, _ctx: ToolContext) -> Result<ToolResult, ToolError> {
        // Prefer the caller's exact words for this turn; the model's argument is
        // only a fallback. This keeps a passive voice agent from paraphrasing
        // the question into something the wrapped agent cannot answer.
        let caller = self
            .turn_text
            .lock()
            .map(|text| text.trim().to_string())
            .unwrap_or_default();
        let model_text = params
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        let text = if caller.is_empty() { model_text } else { caller };
        if text.is_empty() {
            return Err(ToolError::InvalidArgs(
                "voice_forward has nothing to forward".into(),
            ));
        }
        let id = delegation_id(self.turn.load(Ordering::SeqCst), &text);
        match self.agent.forward(&text, &id).await {
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
