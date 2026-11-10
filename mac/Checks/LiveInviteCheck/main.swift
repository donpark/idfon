// Runnable check for the mac tree's `LiveInvite` build/parse (not part of the
// SwiftPM target). Same contract as ios/Checks/LiveInviteCheck — the seam is
// duplicated in both trees, so the check runs in both.
//
//   swiftc -o /tmp/liveinvitecheck \
//     mac/Sources/Idfon/LiveInvite.swift \
//     mac/Checks/LiveInviteCheck/main.swift
//   /tmp/liveinvitecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let addr = "{\"id\":\"abc=123\",\"addrs\":[{\"Relay\":\"https://usw1-1.relay.n0.iroh.link./\"}]}"
let built = LiveInvite.build(action: "start", ticket: "t-1", call: true, addr: addr)
guard let parsed = LiveInvite.parse(built) else { print("FAIL: parse returned nil"); exit(1) }
check(parsed.isStart && !parsed.isStop, "action=start parses")
check(parsed.media == "video-call", "media=video-call parses")
check(parsed.ticket == "t-1", "ticket round-trips")
check(parsed.addr == addr, "addr round-trips (base64 padding intact)")

let old = LiveInvite.build(action: "start", ticket: "t-2", call: false)
guard let oldParsed = LiveInvite.parse(old) else { print("FAIL: old format parse"); exit(1) }
check(oldParsed.addr == nil, "missing addr line parses as nil")

let ret = LiveInvite.parse("IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=t-3\nreturn=1")
check(ret?.isReturn == true, "return=1 parses")
let weird = LiveInvite.parse("IDFON-LIVE/1\naction=start\nticket=a=b=c")
check(weird?.ticket == "a=b=c", "values containing '=' survive")
check(LiveInvite.parse("hello") == nil, "non-envelope text is ignored")

check(LiveInvite.parse(LiveInvite.build(action: "start", ticket: "t", call: true, isReturn: true))?.isReturn == true, "return=1 round-trips (the glare marker)")

print("ALL OK")
