import XCTest

@testable import Idfon

/// The per-contact call profile (`ContactCallProfiles`): derived facts (the
/// ticket's signed `voice` block, ticket presence) vs the person screen's
/// stored overrides. App-hosted; runs on device (`ios/test.sh`).
final class ContactCallProfileTests: XCTestCase {
    private let peer = "test-call-profile-peer"

    override func tearDown() {
        ContactCallProfiles.remove(for: peer)
        CapabilityTickets.remove(for: peer)
        super.tearDown()
    }

    func testOrdinaryPeerIsAHumanAndCallableByDefault() {
        let profile = ContactCallProfiles.profile(for: peer)
        XCTAssertEqual(profile.kind, .human)
        XCTAssertTrue(profile.voiceEnabled)
        XCTAssertTrue(ContactCallProfiles.isCallable(peer))
    }

    func testTicketWithAVoiceBlockIsACallableAgent() {
        XCTAssertTrue(CapabilityTickets.store(#"{"voice":{"mode":"client-cascade"}}"#, for: peer))
        let profile = ContactCallProfiles.profile(for: peer)
        XCTAssertEqual(profile.kind, .agent)
        XCTAssertTrue(profile.voiceEnabled, "the holder's signed voice block makes the agent callable")
        XCTAssertTrue(ContactCallProfiles.isCallable(peer))
    }

    func testAgentWithoutAVoiceBlockIsNotCallable() {
        XCTAssertTrue(CapabilityTickets.store(#"{"capabilities":["message.receive"]}"#, for: peer))
        let profile = ContactCallProfiles.profile(for: peer)
        XCTAssertEqual(profile.kind, .agent)
        XCTAssertFalse(profile.voiceEnabled, "a legacy or voice-refusing agent takes no calls")
        XCTAssertFalse(ContactCallProfiles.isCallable(peer))
    }

    func testStoredOverridesWinOverDerivedFacts() {
        XCTAssertTrue(CapabilityTickets.store(#"{"voice":{"mode":"client-cascade"}}"#, for: peer))
        ContactCallProfiles.set(kind: .human, voice: false, for: peer)
        let profile = ContactCallProfiles.profile(for: peer)
        XCTAssertEqual(profile.kind, .human, "the user's kind override wins")
        XCTAssertFalse(profile.voiceEnabled, "a deaf human is not callable")
        XCTAssertFalse(ContactCallProfiles.isCallable(peer))
    }

    func testClearingAnOverrideReturnsToTheDerivedDefault() {
        ContactCallProfiles.set(kind: .agent, voice: false, for: peer)
        XCTAssertFalse(ContactCallProfiles.isCallable(peer))
        ContactCallProfiles.set(kind: nil, voice: nil, for: peer)
        let profile = ContactCallProfiles.profile(for: peer)
        XCTAssertEqual(profile.kind, .human)
        XCTAssertTrue(profile.voiceEnabled)
    }
}
