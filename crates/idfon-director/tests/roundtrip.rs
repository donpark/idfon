use idfon_director::{mock_director, TraceStep};

#[test]
fn one_turn_emits_speak_envelope() {
    let mut director = mock_director("You are a test director.");
    director.prewarm();
    let result = director.turn("say hi");

    assert_eq!(result.envelopes.len(), 1, "one envelope expected");
    assert!(
        result.envelopes[0].starts_with("IDFON-SPEAK/1\n"),
        "envelope must be IDFON-SPEAK/1, got: {}",
        result.envelopes[0]
    );
    assert!(
        result.envelopes[0].contains("hello from the director scaffold"),
        "envelope must carry the spoken text"
    );

    let kinds: Vec<&str> = result.trace.iter().map(|t: &TraceStep| t.kind.as_str()).collect();
    assert!(kinds.contains(&"tool_call"), "trace records the tool call");
    assert!(kinds.contains(&"tool_result"), "trace records the tool result");
}

#[test]
fn wire_text_appends_envelopes_after_the_preamble() {
    let mut director = mock_director("You are a test director.");
    let result = director.turn("say hi");
    let wire = result.wire_text("Sure.");
    assert!(wire.starts_with("Sure.\nIDFON-SPEAK/1\n"), "got: {wire}");
    assert_eq!(
        result.wire_text(""),
        result.envelopes.join("\n"),
        "no preamble leaves the envelopes alone"
    );
}

#[test]
fn speak_definition_matches_the_contract() {
    let def = idfon_director::SpeakTool::definition();
    assert_eq!(def.name, "speak");
    let required = def.parameters["required"].as_array().unwrap();
    assert!(required.iter().any(|v| v == "text"));
}
