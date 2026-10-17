// Runnable check for `RingTicket` (not part of the Xcode target). Guards the
// #52 ticket → caller_id contract: a contact ticket binds the caller as
// `subject`, a self-issued statement as `issuer`, and presentation prefers the
// contact ticket when it binds a subject.
//
//   swiftc -o /tmp/cktktcheck \
//     ios/Idfon/RingTicket.swift ios/Checks/RingTicketCheck/main.swift
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

print("ALL OK")
