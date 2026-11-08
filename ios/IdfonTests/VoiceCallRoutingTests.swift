import XCTest

@testable import Idfon

/// `VoiceCallRouting.decide` — the guard that keeps a text-only holder (client
/// cascade) on the on-device voice call. Such a holder cannot terminate media,
/// so a media session would ring forever ("no answer") no matter what the
/// per-contact engine picks say.
final class VoiceCallRoutingTests: XCTestCase {
    private func route(_ mode: VoiceRoute.Mode, audio: String? = "pcm24k") -> VoiceRoute {
        VoiceRoute(mode: mode, audio: audio, model: nil, delegatePeerId: nil,
                   delegateContact: nil, delegateTicket: nil, stt: nil, tts: nil)
    }

    private func option(id: String, kind: VoiceOption.Kind, side: VoiceOption.Side) -> VoiceOption {
        VoiceOption(json: ["id": id, "kind": kind.rawValue, "label": id, "side": side.rawValue])!
    }

    func testClientCascadeNeverRoutesToMediaCallDespiteServerPick() {
        let catalog = [option(id: "phonon-server", kind: .tts, side: .server)]
        XCTAssertEqual(
            VoiceCallRouting.decide(selection: (stt: nil, tts: "phonon-server"),
                                    catalog: catalog,
                                    signed: route(.clientCascade),
                                    holderTicket: true,
                                    legacyRemote: true),
            .onDevice)
    }

    func testSpeechDefaultsFollowSignedRouteAndAdvertisedServerEngine() {
        let deepgram = VoiceOption(json: [
            "id": "deepgram:nova-3", "kind": "stt", "label": "Deepgram Nova-3", "side": "server",
        ])!
        XCTAssertEqual(
            ContactSpeech.defaultChoice(slot: .recognition, route: route(.serverCascade), catalog: [deepgram],
                                        localId: "nemotron", localTitle: "Nemotron Streaming"),
            SpeechChoice(store: .agentDefault, id: "agent-default", title: "Agent default — Deepgram Nova-3"))
        XCTAssertEqual(
            ContactSpeech.defaultChoice(slot: .recognition, route: route(.clientCascade), catalog: [deepgram],
                                        localId: "nemotron", localTitle: "Nemotron Streaming"),
            SpeechChoice(store: .onDevice, id: "nemotron", title: "Nemotron Streaming"))
        let peer = "test-agent-default-\(UUID().uuidString)"
        ContactOnDeviceEngines.set(slot: .recognition, value: "nemotron", for: peer)
        ContactSpeech.set(
            ContactSpeech.defaultChoice(slot: .recognition, route: route(.serverCascade), catalog: [deepgram],
                                         localId: "nemotron", localTitle: "Nemotron Streaming"),
            catalog: [deepgram], for: peer, slot: .recognition)
        XCTAssertNil(ContactSpeech.stored(for: peer, slot: .recognition), "choosing agent default clears the override")
        ContactOnDeviceEngines.remove(for: peer)
        ContactVoiceSelection.remove(for: peer)
    }

    func testClientCascadeWithOnDevicePicksStaysOnDevice() {
        XCTAssertEqual(
            VoiceCallRouting.decide(selection: (stt: nil, tts: nil),
                                    onDevice: (stt: "nemotron", tts: "phonon"),
                                    catalog: [],
                                    signed: route(.clientCascade),
                                    holderTicket: true,
                                    legacyRemote: true),
            .onDevice)
    }

    func testMediaCapableHolderStillRoutesServerPickToLiveCall() {
        let catalog = [option(id: "gpt-live", kind: .fullDuplex, side: .server)]
        guard case .live = VoiceCallRouting.decide(selection: (stt: nil, tts: "gpt-live"),
                                                   catalog: catalog,
                                                   signed: route(.nativeDuplex),
                                                   holderTicket: true,
                                                   legacyRemote: true) else {
            return XCTFail("a server pick on a media-capable holder must dial live")
        }
    }
}
