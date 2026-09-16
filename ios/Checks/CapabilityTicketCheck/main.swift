// Runnable check for `CapabilityTickets` and the `AnyEncodable` round-trip the
// daemon's `message.send` param depends on (not part of the Xcode target).
// Both files are Foundation-only, so this compiles and runs on the host — no
// simulator needed:
//
//   swiftc -o /tmp/ctcheck \
//     ios/Idfon/AnyEncodable.swift ios/Idfon/CapabilityTickets.swift \
//     ios/Checks/CapabilityTicketCheck/main.swift
//   /tmp/ctcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let peer = "check-peer-\(UUID().uuidString)"

// Shape produced by `idfon-eve-channel ticket` (CapabilityTicket's optional
// subject/expires_at serialize as explicit nulls).
let ticket = """
{"issuer":"aa","subject":"bb","capabilities":["message.receive"],"expires_at":null,"ticket_id":"eve-1","signature":"cc"}
"""

check(CapabilityTickets.ticket(for: peer) == nil, "no ticket before provisioning")
check(!CapabilityTickets.store("not json", for: peer), "invalid json rejected")
check(!CapabilityTickets.store("[1,2]", for: peer), "non-object json rejected")
check(CapabilityTickets.store(ticket, for: peer), "object json stored")

guard let param = CapabilityTickets.ticket(for: peer) else { check(false, "ticket present"); exit(1) }

// The daemon hands this param straight to serde_json::from_value, so the
// encoded param must equal the minted ticket exactly — nulls included.
let encoded = try JSONEncoder().encode(param)
let stored = try JSONSerialization.jsonObject(with: Data(ticket.utf8)) as? NSDictionary
let sent = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
check(sent != nil && stored != nil && sent!.isEqual(stored!), "ticket round-trips through the send param unchanged")

// `expires_at: null` must not abort encoding of the whole request.
check(String(data: encoded, encoding: .utf8)?.contains("\"expires_at\":null") == true, "nested null encodes")

CapabilityTickets.remove(for: peer)
check(CapabilityTickets.ticket(for: peer) == nil, "removed")

print("ALL OK")