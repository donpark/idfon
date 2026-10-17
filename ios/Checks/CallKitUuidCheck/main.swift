// Runnable check for `CallUUID.from(ticket:)` (not part of the Xcode target).
// Guards the CallKit call-identity contract: one ticket maps to one UUID
// (redelivered invites re-report the same call, never a second ring), distinct
// tickets never collide, and the bytes are a valid random-layout UUID.
//
//   swiftc -o /tmp/ckuuidcheck \
//     ios/Idfon/CallUUID.swift ios/Checks/CallKitUuidCheck/main.swift
//   /tmp/ckuuidcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let a1 = CallUUID.from(ticket: "ticket-a")
let a2 = CallUUID.from(ticket: "ticket-a")
let b = CallUUID.from(ticket: "ticket-b")

check(a1 == a2, "same ticket maps to the same UUID")
check(a1 != b, "different tickets map to different UUIDs")
check(a1 != CallUUID.from(ticket: ""), "empty ticket does not collide with a real one")

let bytes = withUnsafeBytes(of: a1.uuid) { Array($0) }
check(bytes[6] >> 4 == 4, "UUID version nibble is 4")
check(bytes[8] >> 6 == 0b10, "UUID variant bits are RFC 4122")

print("ALL OK")
