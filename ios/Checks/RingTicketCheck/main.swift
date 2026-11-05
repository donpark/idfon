// Runnable check for `RingTicket` (not part of the Xcode target). Guards the
// #52 ticket → caller_id contract: a contact ticket binds the caller as
// `subject`, a self-issued statement as `issuer`, and presentation prefers the
// contact ticket when it binds a subject.
//
//   swiftc -o /tmp/cktktcheck \
//     ios/Idfon/RingTicket.swift ios/Idfon/CapabilityTicketToken.swift ios/Checks/RingTicketCheck/main.swift
//   /tmp/cktktcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let contact = RingTicket(json: #"{"issuer":"us","subject":"them","expires":"2030"}"#)
let issued = RingTicket(json: #"{"issuer":"us"}"#)

check(contact?.callerId == "them", "contact ticket: caller_id is the subject")
check(issued?.callerId == "us", "self-issued statement: caller_id is the issuer")
check(RingTicket(json: #"{"issuer":"us","subject":""}"#)?.callerId == "us",
      "an empty subject is unbound: caller_id falls back to the issuer")

check(RingTicket.presentation(contact: contact, issued: issued)?.callerId == "them",
      "presentation prefers the contact ticket when it binds a subject")
check(RingTicket.presentation(contact: issued, issued: issued)?.callerId == "us",
      "a contact ticket without a subject is not presented")
check(RingTicket.presentation(contact: nil, issued: issued)?.callerId == "us",
      "presentation falls back to the self-issued statement")
check(RingTicket.presentation(contact: contact, issued: nil)?.callerId == "them",
      "a bound contact ticket stands alone")
check(RingTicket.presentation(contact: nil, issued: nil) == nil,
      "nothing to present: the ring is skipped")

check(RingTicket(json: #"{"subject":"them"}"#) == nil, "a ticket without an issuer is rejected")
check(RingTicket(json: #"{"issuer":""}"#) == nil, "a blank issuer is rejected")
check(RingTicket(json: "not json") == nil, "malformed JSON is rejected")
check(contact?.raw.contains("them") == true, "the presented ticket is the raw ticket")

// A stored ticket may also be an `rcan` token (the wire form since 0.9.1):
// the caller id is the token's subject.
let token = """
alveu3dd4kofecv66vihwezoyx4zkr3wv27l464siipou2iui3jcyeirceirceirceirceirceirceirceirceirceirceirceirceiraaaybmppqydyuamiaf5sey3bobqwe2lmnf2gszltei5fwitnmvzxgylhmuxhezldmvuxmzjcluwce5djmnvwk5c7nfsceorcmnugky3lfuyselbcozxwsy3fei5hwitnn5sgkir2ejxgc5djozss2zdvobwgk6bcfqrgc5lenfxseorcobrw2mrunmrcyitnn5sgk3bchirg64dfnzqwsl3hob2c23djozss2mjcpv66z3cfp25t6s5mlwrxot645s6b6cw3lhydc2npoa5bof5q7kf5vctbqzc4q2cpvleofxd2xxxgmvqmsjo5nzke4nb2jvhqyug3komzbm
""".trimmingCharacters(in: .whitespacesAndNewlines)
check(
    RingTicket(json: token)?.callerId == "1111111111111111111111111111111111111111111111111111111111111111",
    "a token ticket binds its subject as the caller id")
check(RingTicket(json: token)?.issuer == "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c",
      "a token ticket carries its issuer")
check(RingTicket(json: "alveu3") == nil, "a malformed token is rejected")

print("ALL OK")
