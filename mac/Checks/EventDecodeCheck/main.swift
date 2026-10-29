// Host check: the daemon's message.received wire JSON must decode into an
// Event with non-nil messageText/messagePeerId through the AnyEncodable
// round-trip (JSONDecoder -> [AnyEncodable] -> re-encode -> [Event]) — the
// exact path `DaemonClient.events` uses. A nil there is swallowed silently by
// ChatStore.ingest's first guard (no log, no machine action), which is how a
// hangup stop vanished between the daemon store and the call machines
// (the #51 E2E "mac stayed in calling mode" trace).
//
//   swiftc -o /tmp/event-decode-check ios/Idfon/AnyEncodable.swift \
//     mac/Sources/Idfon/JSONRenderModel.swift mac/Sources/Idfon/Models.swift \
//     mac/Sources/Idfon/Artifact.swift mac/Checks/EventDecodeCheck/main.swift
//   /tmp/event-decode-check
//
// Prints "ALL OK" or the failing assertions (exit 1).
import Foundation

// The exact event the daemon held at cursor cur_...681 (msg_247: the callee's
// hangup stop), plus its batch neighbours that DID ingest.
let wire = """
{"events":[
 {"cursor":"cur_00000000000000000679","data":{"conversation":null,"message_id":"msg_245","peer_id":"9204ab85464fa151ab35088715e6daf61fb70de150e9b44cc412fe43dc9a3e00","text":"IDFON-LIVE/1\\naction=start\\nticket=iroh-live:ghdOi-iq3j9Je6RUX0Th31fkjbundbeD47upN-hwWlY/idfon-live-29944\\naudio_codec=opus\\naudio_sample_rate=48000"},"event_id":"evt_msg_245","identity":"default","timestamp":"1793252164","type":"message.received"},
 {"cursor":"cur_00000000000000000681","data":{"conversation":null,"message_id":"msg_247","peer_id":"9204ab85464fa151ab35088715e6daf61fb70de150e9b44cc412fe43dc9a3e00","text":"IDFON-LIVE/1\\naction=stop\\nmedia=video\\nticket=iroh-live:d9_Q6yyM2AZiyzjbOLjKQbwSvkIQrWU_c_twCPofIYk/idfon-live-29980"},"event_id":"evt_msg_247","identity":"default","timestamp":"1793252177","type":"message.received"},
 {"cursor":"cur_00000000000000000682","data":{"conversation":null,"message_id":"msg_250","peer_id":"9204ab85464fa151ab35088715e6daf61fb70de150e9b44cc412fe43dc9a3e00","text":"IDFON-LIVE/1\\naction=start\\nmedia=video-call\\nticket=iroh-live:nyvKzD51ZHRKUmFYLZsn67RtDMHL4dYGVbKKuKO6G-A/idfon-live-29944"},"event_id":"evt_msg_250","identity":"default","timestamp":"1793252191","type":"message.received"}
]}
"""

// The real `Event` (Models.swift) already carries messageText/messagePeerId;
// the check exercises it alongside AnyEncodable — the exact pair
// `DaemonClient.events` decodes through.

var failures = 0
func expect(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL"): \(what)")
    if !ok { failures += 1 }
}

do {
    // Exact mirror of `DaemonClient.events`: response result -> ["events"] ->
    // asArray -> re-encode -> decode [Event].
    let result = try JSONDecoder().decode(AnyEncodable.self, from: Data(wire.utf8))
    guard let list = result["events"]?.asArray else {
        expect(false, "events array missing after AnyEncodable subscript")
        exit(1)
    }
    let events = try JSONDecoder().decode([Event].self, from: JSONEncoder().encode(list))
    expect(events.count == 3, "batch decodes to 3 events")
    for event in events {
        expect(event.messageText != nil, "\(event.eventId) messageText non-nil")
        expect(event.messagePeerId != nil, "\(event.eventId) messagePeerId non-nil")
        if let text = event.messageText {
            expect(text.hasPrefix("IDFON-LIVE/1"), "\(event.eventId) text intact")
        }
    }
} catch {
    expect(false, "decode threw: \(error)")
}

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("ALL OK")
