// Runnable check for `LiveInvite` build/parse (not part of the Xcode target).
// Guards the call-invite wire envelope — the seam where the C20 media-address
// line lives and where tonight's bugs hid: the `addr=` round-trip (base64,
// including `=` padding inside the value), old-format tolerance (no addr
// line), `call_mode`/`return` flags, and first-`=` field splitting.
//
//   swiftc -o /tmp/liveinvitecheck \
//     ios/Idfon/Models.swift ios/Idfon/LiveInvite.swift \
//     ios/Checks/LiveInviteCheck/main.swift
//   /tmp/liveinvitecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// Round trip: start video invite with an addr carrying base64 padding ("=").
let addr = "{\"id\":\"abc=123\",\"addrs\":[{\"Relay\":\"https://usw1-1.relay.n0.iroh.link./\"}]}"
let built = LiveInvite.build(action: "start", ticket: "t-1", call: true, callMode: .callKit, addr: addr)
guard let parsed = LiveInvite.parse(built) else { print("FAIL: parse returned nil"); exit(1) }
check(parsed.isStart && !parsed.isStop, "action=start parses")
check(parsed.isCall && parsed.media == "video-call", "media=video-call parses")
check(parsed.ticket == "t-1", "ticket round-trips")
check(parsed.callMode == .callKit, "call_mode=call_kit round-trips")
check(parsed.addr == addr, "addr round-trips (base64 padding intact)")

// Old-format tolerance: envelopes from peers without the addr line.
let old = LiveInvite.build(action: "start", ticket: "t-2", call: false)
guard let oldParsed = LiveInvite.parse(old) else { print("FAIL: old format parse"); exit(1) }
check(oldParsed.addr == nil, "missing addr line parses as nil")
check(!oldParsed.isCall && oldParsed.media == "video", "audio/file media parses")
check(oldParsed.callMode == nil, "missing call_mode parses as nil (consumers default to bar)")

// Return legs and stops.
let ret = LiveInvite.parse("IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=t-3\nreturn=1")
check(ret?.isReturn == true, "return=1 parses")
let stop = LiveInvite.parse("IDFON-LIVE/1\naction=stop\nticket=t-4")
check(stop?.isStop == true && stop?.ticket == "t-4", "stop parses")

// Field splitting: only the first "=" splits a line.
let weird = LiveInvite.parse("IDFON-LIVE/1\naction=start\nticket=a=b=c")
check(weird?.ticket == "a=b=c", "values containing '=' survive")

// Garbage never parses as an invite.
check(LiveInvite.parse("hello") == nil, "non-envelope text is ignored")
check(LiveInvite.parse("IDFON-LIVE/1\nno-action-line") == nil, "missing action is ignored")

// Determinism: parsing the built form twice is stable.
check(LiveInvite.parse(built)?.addr == parsed.addr, "parse is stable")

check(LiveInvite.parse(LiveInvite.build(action: "start", ticket: "t", call: true, isReturn: true))?.isReturn == true, "return=1 round-trips (the glare marker)")

print("ALL OK")
