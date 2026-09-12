// Runnable decode check for `IncomingCallMode` / `Peer.call_mode` (not part
// of the Xcode target). Guards the contract that the `peers` array never fails
// to decode when a daemon sends a mode iOS does not know:
//
//   swiftc -o /tmp/icmcheck \
//     ios/Idfon/Models.swift ios/Checks/IncomingCallModeDecodeCheck/main.swift
//   /tmp/icmcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// Models.swift's `Event` needs the type/conformance; the check never decodes one.
struct AnyEncodable: Decodable { let value: Any
    init(from decoder: Decoder) throws { value = NSNull() }
}

struct PeersResponse: Decodable { let peers: [Peer] }

let json = """
{"peers":[
  {"id":"absent","name":"A"},
  {"id":"bar","call_mode":"bar"},
  {"id":"kit","call_mode":"call_kit"},
  {"id":"future","call_mode":"telepathy"},
  {"id":"null","call_mode":null},
  {"id":"number","call_mode":42}
]}
"""

let peers = try JSONDecoder().decode(PeersResponse.self, from: Data(json.utf8)).peers
let byId: [String: IncomingCallMode] = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.incomingCallMode) })
let bar = IncomingCallMode.bar, kit = IncomingCallMode.callKit
check(byId["absent"] == bar, "absent call_mode resolves to .bar")
check(byId["bar"] == bar, "bar decodes to .bar")
check(byId["kit"] == kit, "call_kit decodes to .callKit")
check(byId["future"] == bar, "unrecognized value resolves to .bar (array still decodes)")
check(byId["null"] == bar, "null resolves to .bar")
check(byId["number"] == bar, "non-string value resolves to .bar")
print("ALL OK")
