// Runnable check for `CapabilityTickets` and the `AnyEncodable` round-trip the
// daemon's `message.send` param depends on (not part of the Xcode target).
// Both files are Foundation-only, so this compiles and runs on the host — no
// simulator needed:
//
//   swiftc -o /tmp/ctcheck \
//     ios/Idfon/AnyEncodable.swift ios/Idfon/CapabilityTickets.swift \
//     ios/Idfon/CapabilityTicketToken.swift \
//     ios/Checks/CapabilityTicketCheck/main.swift
//   /tmp/ctcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let peer = "check-peer-\(UUID().uuidString)"

// A real `rcan` token minted by idfon-core for key 07..07, subject 11..11,
// capability message.receive, expiry 2030-01-01, voice native-duplex/pcm24k.
// Regenerate with any `issue_capability_ticket_with_voice` call if the wire
// format changes.
let token = """
alveu3dd4kofecv66vihwezoyx4zkr3wv27l464siipou2iui3jcyeirceirceirceirceirceirceirceirceirceirceirceirceiraaaybmppqydyuamiaf5sey3bobqwe2lmnf2gszltei5fwitnmvzxgylhmuxhezldmvuxmzjcluwce5djmnvwk5c7nfsceorcmnugky3lfuyselbcozxwsy3fei5hwitnn5sgkir2ejxgc5djozss2zdvobwgk6bcfqrgc5lenfxseorcobrw2mrunmrcyitnn5sgk3bchirg64dfnzqwsl3hob2c23djozss2mjcpv66z3cfp25t6s5mlwrxot645s6b6cw3lhydc2npoa5bof5q7kf5vctbqzc4q2cpvleofxd2xxxgmvqmsjo5nzke4nb2jvhqyug3komzbm
""".trimmingCharacters(in: .whitespacesAndNewlines)

let issuer = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
let subject = "1111111111111111111111111111111111111111111111111111111111111111"

// --- the token reader ------------------------------------------------------
let fields = CapabilityTicketToken.parse(token)
check(fields != nil, "token parses")
check(fields?.issuer == issuer, "issuer is the signing key")
check(fields?.subject == subject, "subject is the audience")
check(fields?.expiresAt == 1_893_456_000, "expiry is the signed epoch")
check((fields?.document["capabilities"] as? [String]) == ["message.receive"], "capabilities ride in the document")
check((fields?.document["ticket_id"] as? String) == "check-1", "ticket id rides in the document")
check(CapabilityTicketToken.parse("not-a-token") == nil, "garbage is rejected")
check(CapabilityTicketToken.parse(String(token.prefix(40))) == nil, "a truncated token is rejected")

// --- storage + the send param ---------------------------------------------
check(CapabilityTickets.ticket(for: peer) == nil, "no ticket before provisioning")
check(!CapabilityTickets.store("", for: peer), "empty is rejected")
check(!CapabilityTickets.store("not a token", for: peer), "garbage is rejected")
check(
    !CapabilityTickets.store(#"{"issuer":"aa","subject":"bb","signature":"cc"}"#, for: peer),
    "a legacy JSON ticket is rejected")
check(CapabilityTickets.store("  \(token)\n", for: peer), "token stored (whitespace trimmed)")
check(CapabilityTickets.hasTicket(for: peer), "hasTicket sees it")
check(CapabilityTickets.rawTicket(for: peer) == token, "raw ticket is the token, for x-idfon-ticket")

guard let param = CapabilityTickets.ticket(for: peer) else { check(false, "ticket present"); exit(1) }
// The daemon hands this param straight to serde_json::from_value::<CapabilityTicket>,
// which decodes a ticket from its token string.
let encoded = try JSONEncoder().encode(param)
let sent = try JSONDecoder().decode(String.self, from: encoded)
check(sent == token, "the send param is the bare token string")

// --- voice routing ---------------------------------------------------------
let route = CapabilityTickets.voiceRoute(for: peer)
check(route?.mode == .nativeDuplex, "voice mode comes from the signed document")
check(route?.audio == "pcm24k", "voice profile comes from the signed document")
check(route?.model == "openai/gpt-live-1", "voice model comes from the signed document")

CapabilityTickets.remove(for: peer)
check(CapabilityTickets.ticket(for: peer) == nil, "removed")
check(CapabilityTickets.voiceRoute(for: peer) == nil, "no route after removal")

print("ALL OK")
