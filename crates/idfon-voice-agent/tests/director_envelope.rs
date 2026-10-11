//! The director's wire reply is parsed by the same function the cascade uses to
//! decide what to speak (`speak_text`), so the app acts on the envelope.

use idfon_director::mock_director;
use idfon_voice_agent::{speak_text, strip_envelopes};

#[test]
fn director_envelope_is_parsed_by_the_voice_agent() {
    let mut director = mock_director("You are a test director.");
    let turn = director.turn("say hi");
    let wire = turn.wire_text("");

    assert!(wire.starts_with("IDFON-SPEAK/1\n"), "got: {wire}");
    assert_eq!(speak_text(&wire), "hello from the director scaffold");
    assert_eq!(strip_envelopes(&wire), "");
}

#[test]
fn preamble_survives_the_envelope_parse() {
    let mut director = mock_director("You are a test director.");
    let turn = director.turn("say hi");
    let wire = turn.wire_text("One moment.");

    assert_eq!(strip_envelopes(&wire), "One moment.");
    assert_eq!(speak_text(&wire), "hello from the director scaffold");
}
