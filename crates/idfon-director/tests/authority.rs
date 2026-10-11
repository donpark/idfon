//! Authority: propose vs authorize (#37). See `docs/voice-decisions.md`.

use idfon_director::authority::Authority;
use idfon_director::Director;
use serde_json::json;
use yoagent::decision::{DecisionError, DecisionModel, MockBackend};
use yoagent::provider::mock::{MockResponse, MockToolCall};
use yoagent::provider::MockProvider;

fn call(name: &str, args: serde_json::Value) -> MockResponse {
    MockResponse::ToolCalls(vec![MockToolCall {
        name: name.into(),
        arguments: args,
        provider_metadata: None,
    }])
}

fn speak(text: &str) -> MockResponse {
    call("speak", json!({ "text": text }))
}

/// A granted tool runs; nothing is refused.
#[test]
fn a_granted_tool_runs() {
    let provider = MockProvider::new(vec![speak("hi"), MockResponse::Text("done".into())]);
    let mut director =
        Director::with_authority(provider, "test", Authority::grant(["speak"]), None, None);
    let turn = director.turn("say hi");
    assert_eq!(turn.envelopes.len(), 1);
    assert!(turn.trace().iter().all(|t| t.kind != "denied"));
}

/// No grant: the call is denied, does not execute, and the loop continues.
#[test]
fn an_ungranted_tool_fails_closed() {
    let provider = MockProvider::new(vec![speak("hi"), MockResponse::Text("done".into())]);
    let mut director =
        Director::with_authority(provider, "test", Authority::grant(["decide"]), None, None);
    let turn = director.turn("say hi");
    assert!(
        turn.envelopes.is_empty(),
        "the denied tool must not execute"
    );
    let denied: Vec<_> = turn.trace().iter().filter(|t| t.kind == "denied").collect();
    assert_eq!(denied.len(), 1);
    assert_eq!(denied[0].name.as_deref(), Some("speak"));
    assert!(
        denied[0].detail.as_deref().unwrap_or("").contains("grant"),
        "refusal names the reason: {:?}",
        denied[0].detail
    );
    assert!(
        turn.trace().iter().any(|t| t.kind == "model"),
        "the loop must not stall: {:?}",
        turn.trace()
    );
}

/// A spent budget denies the next call; the loop continues.
#[test]
fn a_spent_budget_fails_closed() {
    let provider = MockProvider::new(vec![
        speak("one"),
        speak("two"),
        MockResponse::Text("done".into()),
    ]);
    let mut director = Director::with_authority(
        provider,
        "test",
        Authority::grant(["speak"]).with_budget(1),
        None,
        None,
    );
    let turn = director.turn("say two things");
    assert_eq!(
        turn.envelopes.len(),
        1,
        "only the first call fits the budget"
    );
    assert!(turn
        .trace()
        .iter()
        .any(|t| t.kind == "denied" && t.detail.as_deref().unwrap_or("").contains("budget")));
}

/// A decider that errors allows the call: a call never depends on a decider.
#[test]
fn a_failing_decider_fails_open() {
    let provider = MockProvider::new(vec![speak("hi"), MockResponse::Text("done".into())]);
    let decider = DecisionModel::from_backend(
        MockBackend::from_fn(|_| Err(DecisionError::Invalid("decider down".into()))),
        "mock",
    );
    let mut director = Director::with_authority(
        provider,
        "test",
        Authority::grant(["speak"]).with_decider(decider, 0.5),
        None,
        None,
    );
    let turn = director.turn("say hi");
    assert_eq!(turn.envelopes.len(), 1);
    assert!(turn.trace().iter().all(|t| t.kind != "denied"));
}

/// A decider may propose a veto; code honors it (fail-closed).
#[test]
fn a_decider_veto_fails_closed() {
    let provider = MockProvider::new(vec![speak("hi"), MockResponse::Text("done".into())]);
    let decider = DecisionModel::from_backend(MockBackend::neutral(), "mock");
    let mut director = Director::with_authority(
        provider,
        "test",
        Authority::grant(["speak"]).with_decider(decider, 0.4),
        None,
        None,
    );
    let turn = director.turn("say hi");
    assert!(turn.envelopes.is_empty());
    assert!(turn
        .trace()
        .iter()
        .any(|t| t.kind == "denied" && t.detail.as_deref().unwrap_or("").contains("decider")));
}

/// A child delegation cannot raise the parent's remaining budget.
#[test]
fn a_child_cannot_raise_the_parent_budget() {
    let parent = Authority::grant(["speak"]).with_budget(2);
    assert_eq!(parent.delegate(50).remaining(), Some(2));
    assert_eq!(parent.delegate(1).remaining(), Some(1));

    // Spends are shared: the child works from the parent's ledger.
    let child = parent.delegate(2);
    assert_eq!(parent.used(), 0);
    assert_eq!(child.remaining(), Some(2));
}
