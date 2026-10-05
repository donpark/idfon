// Runnable check for the per-contact voice-call resolution (not part of the
// Xcode target). The model/resolver files are Foundation-only, so this compiles
// and runs on the host — no simulator needed:
//
//   swiftc -o /tmp/vcrcheck ios/Idfon/AnyEncodable.swift \
//     ios/Idfon/CapabilityTickets.swift ios/Idfon/VoiceCallRouting.swift \
//     ios/Checks/VoiceCallRoutingCheck/main.swift
//   /tmp/vcrcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// `VoiceCatalog` names the gateway fetch; the check exercises the resolver only.
final class DaemonClient {
    func fetchRemoteResource(account: String, path: String) async throws -> Data {
        throw NSError(domain: "check", code: 1)
    }
}

func route(_ mode: VoiceRoute.Mode, audio: String? = nil, model: String? = nil,
           delegate: String? = nil) -> VoiceRoute {
    VoiceRoute(mode: mode, audio: audio, model: model,
               delegatePeerId: delegate, delegateContact: nil, delegateTicket: nil,
               stt: nil, tts: nil)
}

func option(_ id: String, _ kind: String, _ side: String) -> VoiceOption {
    VoiceOption(json: ["id": id, "kind": kind, "label": id, "side": side])!
}

let duplex = route(.nativeDuplex, audio: "pcm24k", model: "openai/gpt-live-1")
let serverStt = option("deepgram:nova-3", "stt", "server")
let clientStt = option("on-device:parakeet", "stt", "client")
let fullDuplex = option("openai/gpt-live-1", "full-duplex", "server")
let catalog = [serverStt, clientStt, fullDuplex]

// No selection: follow the signed route (legacy heuristic only when absent).
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: route(.clientCascade), legacyRemote: true) == .onDevice,
      "no selection + client-cascade -> on-device")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: duplex, legacyRemote: false) == .live(duplex),
      "no selection + native-duplex -> live")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: route(.delegated, delegate: "voice1"), legacyRemote: false) == .delegated(route(.delegated, delegate: "voice1")),
      "no selection + delegated -> delegated")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: nil, legacyRemote: true) == .live(nil),
      "no selection + no ticket + legacy -> live")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: nil, legacyRemote: false) == .classic,
      "no selection + no ticket -> classic")

// A server or full-duplex selection means the holder terminates audio.
check(VoiceCallRouting.decide(selection: ("deepgram:nova-3", nil), catalog: catalog, signed: duplex, legacyRemote: false) == .live(duplex),
      "server STT selection -> live")
check(VoiceCallRouting.decide(selection: (nil, "openai/gpt-live-1"), catalog: catalog, signed: duplex, legacyRemote: false) == .live(duplex),
      "full-duplex selection -> live")
// An all-client selection is a client cascade, regardless of the ticket.
check(VoiceCallRouting.decide(selection: ("on-device:parakeet", nil), catalog: catalog, signed: duplex, legacyRemote: false) == .onDevice,
      "client STT selection -> on-device")

// Selection store: unset by default; per-half; clearing one keeps the other.
let peer = "check-peer-\(UUID().uuidString)"
check(ContactVoiceSelection.selection(for: peer).stt == nil, "default selection is empty")
ContactVoiceSelection.set(stt: "deepgram:nova-3", tts: "openai/gpt-live-1", for: peer)
check(ContactVoiceSelection.selection(for: peer).stt == "deepgram:nova-3", "stt persists")
check(ContactVoiceSelection.inviteLines(for: peer).contains("stt=deepgram:nova-3"), "invite carries stt")
check(ContactVoiceSelection.inviteLines(for: peer).contains("tts=openai/gpt-live-1"), "invite carries tts")
ContactVoiceSelection.set(stt: nil, tts: "openai/gpt-live-1", for: peer)
check(ContactVoiceSelection.selection(for: peer).stt == nil, "stt cleared")
check(ContactVoiceSelection.selection(for: peer).tts == "openai/gpt-live-1", "tts kept")
ContactVoiceSelection.remove(for: peer)
check(ContactVoiceSelection.selection(for: peer).tts == nil, "remove clears the entry")

print("ALL OK")
