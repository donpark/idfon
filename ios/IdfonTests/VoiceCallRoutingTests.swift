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
        let catalog = [option(id: "kokoro-server", kind: .tts, side: .server)]
        XCTAssertEqual(
            VoiceCallRouting.decide(selection: (stt: nil, tts: "kokoro-server"),
                                    catalog: catalog,
                                    signed: route(.clientCascade),
                                    holderTicket: true,
                                    legacyRemote: true),
            .onDevice)
    }

    func testClientCascadeWithOnDevicePicksStaysOnDevice() {
        XCTAssertEqual(
            VoiceCallRouting.decide(selection: (stt: nil, tts: nil),
                                    onDevice: (stt: "parakeet", tts: "kokoro"),
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
