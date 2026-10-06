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
func isLive(_ decision: VoiceCallDecision) -> Bool { if case .live = decision { return true }; return false }

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
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: route(.clientCascade), holderTicket: false, legacyRemote: true) == .onDevice,
      "no selection + client-cascade -> on-device")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false) == .live(duplex),
      "no selection + native-duplex -> live")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: route(.delegated, delegate: "voice1"), holderTicket: false, legacyRemote: false) == .delegated(route(.delegated, delegate: "voice1")),
      "no selection + delegated -> delegated")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: nil, holderTicket: false, legacyRemote: true) == .live(nil),
      "no selection + no ticket + legacy -> live")
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: nil, holderTicket: false, legacyRemote: false) == .classic,
      "ordinary peer (no ticket) -> classic video call")
// A holder ticket with no `voice` block is a text agent: client cascade, not
// the silent video-call fallback.
check(VoiceCallRouting.decide(selection: (nil, nil), catalog: catalog, signed: nil, holderTicket: true, legacyRemote: false) == .onDevice,
      "no voice block + holder ticket -> on-device")

// A server or full-duplex selection means the holder terminates audio.
check(isLive(VoiceCallRouting.decide(selection: ("deepgram:nova-3", nil), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false)),
      "server STT selection -> live")
check(isLive(VoiceCallRouting.decide(selection: (nil, "openai/gpt-live-1"), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false)),
      "full-duplex selection -> live")
// An all-client selection is a client cascade, regardless of the ticket.
check(VoiceCallRouting.decide(selection: ("on-device:parakeet", nil), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false) == .onDevice,
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

// On-device engine choice: unset by default; per-half; removed with the contact.
check(ContactOnDeviceEngines.asr(for: peer) == nil, "default on-device asr is unset")
ContactOnDeviceEngines.set(asr: "parakeet", tts: "kokoro", for: peer)
check(ContactOnDeviceEngines.asr(for: peer) == "parakeet", "on-device asr persists")
check(ContactOnDeviceEngines.tts(for: peer) == "kokoro", "on-device tts persists")
ContactOnDeviceEngines.set(asr: nil, tts: "kokoro", for: peer)
check(ContactOnDeviceEngines.asr(for: peer) == nil, "on-device asr cleared")
check(ContactOnDeviceEngines.tts(for: peer) == "kokoro", "on-device tts kept")
ContactOnDeviceEngines.remove(for: peer)
check(ContactOnDeviceEngines.tts(for: peer) == nil, "on-device remove clears the entry")

// Unified Speech pickers: one view over on-device + catalog, no "Automatic".
check(ContactSpeech.stored(for: peer, slot: .recognition) == nil, "speech pick defaults to nil")
ContactSpeech.set(SpeechChoice(store: .onDevice, id: "parakeet", title: ""), catalog: catalog, for: peer, slot: .recognition)
check(ContactSpeech.stored(for: peer, slot: .recognition) == SpeechChoice(store: .onDevice, id: "parakeet", title: ""),
      "on-device recognition pick persists")
check(ContactSpeech.stored(for: peer, slot: .generation) == nil, "generation unaffected by the recognition pick")
ContactSpeech.set(SpeechChoice(store: .catalog, id: "deepgram:nova-3", title: ""), catalog: catalog, for: peer, slot: .recognition)
check(ContactSpeech.stored(for: peer, slot: .recognition) == SpeechChoice(store: .catalog, id: "deepgram:nova-3", title: ""),
      "catalog pick replaces the on-device pick")
// A full-duplex option fills both halves.
ContactSpeech.set(SpeechChoice(store: .catalog, id: "openai/gpt-live-1", title: ""), catalog: catalog, for: peer, slot: .recognition)
check(ContactSpeech.stored(for: peer, slot: .generation) == SpeechChoice(store: .catalog, id: "openai/gpt-live-1", title: ""),
      "full-duplex fills the other half")
// nil clears both stores for the half.
ContactSpeech.set(nil, catalog: catalog, for: peer, slot: .generation)
check(ContactSpeech.stored(for: peer, slot: .generation) == nil, "nil clears the pick")
ContactVoiceSelection.remove(for: peer)
ContactOnDeviceEngines.remove(for: peer)

// An explicit on-device pick forces the client cascade, even with a live route.
check(VoiceCallRouting.decide(selection: (nil, nil), onDevice: ("apple", nil), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false) == .onDevice,
      "on-device pick beats a native-duplex route")
check(VoiceCallRouting.decide(selection: (nil, nil), onDevice: (nil, "kokoro"), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false) == .onDevice,
      "on-device TTS pick beats a native-duplex route")
// A server catalog pick still wins (the holder terminates audio).
check(isLive(VoiceCallRouting.decide(selection: ("deepgram:nova-3", nil), onDevice: (nil, "kokoro"), catalog: catalog, signed: duplex, holderTicket: false, legacyRemote: false)),
      "server catalog pick still routes live")

// Invite lines can carry the caller's pushed per-turn context.
let invite = ContactVoiceSelection.inviteLines(for: peer, context: "Client STT=Apple Built-in")
check(invite.contains("context_b64="), "invite carries caller context")
check(!ContactVoiceSelection.inviteLines(for: peer).contains("context_b64="), "no context line when unset")

// Client halves drive the live-invite context line.
let hybridRoute = VoiceRoute(mode: .serverCascade, audio: nil, model: nil,
                             delegatePeerId: nil, delegateContact: nil, delegateTicket: nil,
                             stt: .client, tts: .server)
check(hybridRoute.clientHalves == [.recognition], "hybrid route reports the client STT half")
check(duplex.clientHalves.isEmpty, "full-duplex route has no client halves")

// Per-contact picks override the signed half-ownership (true hybrid).
let onDeviceHybrid = duplex.resolving(selection: (nil, nil), onDevice: ("apple", nil), catalog: catalog)
check(onDeviceHybrid.sttSide == .client, "on-device pick overrides the signed STT half to client")
check(onDeviceHybrid.ttsSide == .server, "untouched half keeps the signed server default")
check(onDeviceHybrid.isHybrid, "per-contact on-device pick yields a hybrid route")
check(duplex.resolving(selection: (nil, nil), onDevice: (nil, nil), catalog: catalog) == duplex,
      "no picks leaves the signed route unchanged")
ContactOnDeviceEngines.set(asr: "system", tts: nil, for: peer)
let sideInvite = ContactVoiceSelection.inviteLines(for: peer)
check(sideInvite.contains("stt_side=client"), "invite marks the on-device half client")
check(!sideInvite.contains("tts_side=client"), "invite leaves the holder half server")
ContactOnDeviceEngines.remove(for: peer)

print("ALL OK")
