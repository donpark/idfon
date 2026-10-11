//! Run traces as data (#40): contract schema, content-addressed versions,
//! deterministic ids.

use std::sync::Arc;

use async_trait::async_trait;
use idfon_director::authority::Authority;
use idfon_director::mock_director;
use idfon_director::trace::{content_hash, TraceRecord};
use idfon_director::turn_input::ReferenceResolver;
use idfon_director::{Director, DirectorOptions};
use idfon_protocol::artifacts::ArtifactSelector;
use serde_json::Value;

struct NoopResolver;

#[async_trait]
impl ReferenceResolver for NoopResolver {
    async fn resolve(&self, _ticket: &str, _selector: &ArtifactSelector) -> Result<Value, String> {
        Ok(Value::Null)
    }
}

fn json(record: &TraceRecord) -> Value {
    serde_json::to_value(record).expect("record serializes")
}

/// A full run serializes to the contract record.
#[test]
fn a_turn_produces_a_contract_trace() {
    let mut director = mock_director("# Identity\nTest.\n# Output rules\nShort.");
    let turn = director.turn("say hi");
    let record = json(&turn.record);

    for key in [
        "trace_id",
        "parent_id",
        "turn_id",
        "step",
        "ts",
        "tier",
        "provider",
        "model",
        "prompt",
        "tools",
        "input",
        "steps",
        "output",
        "outcome",
        "redaction",
    ] {
        assert!(
            record.get(key).is_some(),
            "missing trace key {key}: {record}"
        );
    }

    assert!(record["parent_id"].is_null());
    assert!(record["steps"][0]["args"].is_object());
    assert_eq!(record["input"]["text"], "say hi");
    assert_eq!(record["input"]["parts"][0], "text");
    assert_eq!(record["outcome"]["status"], "ok");
    assert_eq!(
        record["output"]["speak"],
        "hello from the director scaffold"
    );
    assert_eq!(record["redaction"]["local_only"], true);
    assert_eq!(record["prompt"]["sections"][0], "Identity");
    assert!(record["prompt"]["version"]
        .as_str()
        .unwrap()
        .starts_with("blake3:"));
    assert!(record["tools"]["hash"]
        .as_str()
        .unwrap()
        .starts_with("blake3:"));

    let ts = record["ts"].as_str().unwrap();
    assert_eq!(ts.len(), 20, "RFC3339 seconds: {ts}");
    assert!(ts.ends_with('Z') && ts.contains('T'));

    let kinds: Vec<&str> = turn.trace().iter().map(|step| step.kind.as_str()).collect();
    assert!(kinds.contains(&"tool_call") && kinds.contains(&"tool_result"));
    assert!(
        turn.trace()
            .iter()
            .all(|step| step.kind != "tool_result" || step.ok == Some(true)),
        "a successful turn records ok results"
    );
}

/// Prompt and tool schemas are content-addressed: same content, same version;
/// different content, different version.
#[test]
fn prompt_and_tools_are_versioned_by_content() {
    use yoagent::provider::mock::{MockResponse, MockToolCall};
    use yoagent::provider::MockProvider;

    let make = |instructions: &str, resolver: Option<Arc<dyn ReferenceResolver>>| {
        let provider = MockProvider::new(vec![
            MockResponse::ToolCalls(vec![MockToolCall {
                name: "speak".into(),
                arguments: serde_json::json!({ "text": "hi" }),
                provider_metadata: None,
            }]),
            MockResponse::Text("done".into()),
        ]);
        Director::new(
            provider,
            instructions,
            DirectorOptions {
                resolver,
                ..Default::default()
            },
        )
    };

    // `content_hash` is stable for the same bytes.
    assert_eq!(content_hash(b"x"), content_hash(b"x"));
    assert_ne!(content_hash(b"x"), content_hash(b"y"));

    let versions = |mut director: Director| {
        let record = director.turn("hi").record;
        (record.prompt.version, record.tools.hash)
    };
    let (prompt_a, tools_a) = versions(make("prompt A", None));
    let (prompt_same, tools_same) = versions(make("prompt A", None));
    let (prompt_b, _) = versions(make("prompt B", None));
    let (_, tools_more) = versions(make("prompt A", Some(Arc::new(NoopResolver))));

    assert_eq!(prompt_a, prompt_same, "same prompt, same version");
    assert_eq!(tools_a, tools_same, "same tools, same hash");
    assert_ne!(
        prompt_a, prompt_b,
        "a different prompt has a different version"
    );
    assert_ne!(tools_a, tools_more, "an added tool changes the schema hash");
}

/// The same input, prompt, and schema produce the same trace and turn ids, so
/// the turn replays deterministically.
#[test]
fn the_same_turn_replays_the_same_ids() {
    let mut first = mock_director("fixed prompt");
    let mut second = mock_director("fixed prompt");
    let a = first.turn("say hi").record;
    let b = second.turn("say hi").record;

    assert_eq!(a.trace_id, b.trace_id);
    assert_eq!(a.turn_id, b.turn_id);
    assert_eq!(a.prompt.version, b.prompt.version);
    assert_eq!(a.tools.hash, b.tools.hash);
    let kinds = |record: &TraceRecord| -> Vec<String> {
        record.steps.iter().map(|step| step.kind.clone()).collect()
    };
    assert_eq!(kinds(&a), kinds(&b));
}

/// A refusal is part of the trace, with its reason.
#[test]
fn a_denied_call_is_in_the_trace() {
    use yoagent::provider::mock::{MockResponse, MockToolCall};
    use yoagent::provider::MockProvider;

    let provider = MockProvider::new(vec![
        MockResponse::ToolCalls(vec![MockToolCall {
            name: "speak".into(),
            arguments: serde_json::json!({ "text": "hi" }),
            provider_metadata: None,
        }]),
        MockResponse::Text("done".into()),
    ]);
    let options = DirectorOptions {
        authority: Some(Authority::grant(["decide"])),
        ..Default::default()
    };
    let mut director = Director::new(provider, "test", options);
    let record = director.turn("say hi").record;

    let denied = record
        .steps
        .iter()
        .find(|step| step.kind == "denied")
        .expect("a denied step");
    assert_eq!(denied.name.as_deref(), Some("speak"));
    assert!(denied.detail.as_deref().unwrap().contains("grant"));
}
