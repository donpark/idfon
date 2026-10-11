//! Wrapped-agent delegation (#38): the remote peer as a normal tool.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use idfon_director::wrapped::WrappedAgent;
use idfon_director::Director;
use serde_json::json;
use yoagent::provider::mock::{MockResponse, MockToolCall};
use yoagent::provider::MockProvider;

fn call(name: &str, args: serde_json::Value) -> MockResponse {
    MockResponse::ToolCalls(vec![MockToolCall {
        name: name.into(),
        arguments: args,
        provider_metadata: None,
    }])
}

fn forward(text: &str) -> MockResponse {
    call("voice_forward", json!({ "text": text }))
}

/// A wrapped peer that dedupes by delegation id: a reply that was already
/// produced is returned without doing the work again.
#[derive(Default)]
struct MockWrapped {
    seen: Mutex<Vec<String>>,
    work: AtomicUsize,
}

#[async_trait]
impl WrappedAgent for MockWrapped {
    async fn forward(&self, text: &str, delegation_id: &str) -> Result<String, String> {
        let mut seen = self.seen.lock().unwrap();
        if !seen.iter().any(|id| id == delegation_id) {
            seen.push(delegation_id.to_string());
            self.work.fetch_add(1, Ordering::SeqCst);
        }
        Ok(format!("reply to {text}"))
    }
}

/// The director delegates a turn and speaks the wrapped agent's reply.
#[test]
fn a_wrapped_turn_is_delegated_and_spoken() {
    let wrapped = Arc::new(MockWrapped::default());
    let provider = MockProvider::new(vec![forward("status"), MockResponse::Text("done".into())]);
    let mut director = Director::with_wrapped_agent(provider, "test", wrapped, None, None, None);
    let turn = director.turn("what is the status");

    assert!(
        turn.envelopes
            .iter()
            .any(|e| { e.starts_with("IDFON-SPEAK/1") && e.contains("reply to status") }),
        "the reply must be spoken: {:?}",
        turn.envelopes
    );
    assert!(
        turn.trace()
            .iter()
            .any(|t| t.kind == "tool_call" && t.name.as_deref() == Some("voice_forward")),
        "the trace records the delegation: {:?}",
        turn.trace()
    );
    assert!(
        turn.trace()
            .iter()
            .any(|t| t.kind == "tool_result" && t.name.as_deref() == Some("voice_forward")),
        "the trace records the returned result: {:?}",
        turn.trace()
    );
}

/// A retried forward in one turn reuses the delegation id, so the remote peer
/// does the work once even if the first reply was lost.
#[test]
fn a_lost_reply_does_not_duplicate_work() {
    let wrapped = Arc::new(MockWrapped::default());
    let provider = MockProvider::new(vec![
        forward("status"),
        forward("status"),
        MockResponse::Text("done".into()),
    ]);
    let mut director =
        Director::with_wrapped_agent(provider, "test", wrapped.clone(), None, None, None);
    director.turn("what is the status");

    assert_eq!(wrapped.work.load(Ordering::SeqCst), 1, "work must run once");
    let ids = wrapped.seen.lock().unwrap();
    assert_eq!(ids.len(), 1, "both attempts share one delegation id");
}

/// Each turn gets its own delegation id.
#[test]
fn a_new_turn_gets_a_new_delegation_id() {
    let wrapped = Arc::new(MockWrapped::default());
    let provider = MockProvider::new(vec![
        forward("one"),
        MockResponse::Text("done".into()),
        forward("two"),
        MockResponse::Text("done".into()),
    ]);
    let mut director =
        Director::with_wrapped_agent(provider, "test", wrapped.clone(), None, None, None);
    director.turn("first");
    director.turn("second");

    let ids = wrapped.seen.lock().unwrap();
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1], "turns must not share a delegation id");
}
