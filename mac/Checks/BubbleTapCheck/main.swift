// BubbleTapCheck: the spoken-bubble tap decision (#202 P0), run as
// `swiftc -o /tmp/bubbletapcheck <app>/BubbleTap.swift <app>/Checks/BubbleTapCheck/main.swift && /tmp/bubbletapcheck`.
// Covers the six decisions: stop-the-reading-bubble, the call guard, blank
// text, a streaming turn, the caller turn (no silent substitution), and play.

import Foundation

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok  \(what)")
    } else {
        print("FAIL \(what)")
        exit(1)
    }
}

let play = BubbleTap.action(role: "agent", text: "Hello there.", final: true, callActive: false, reading: false)
check(play == .play, "final agent turn plays")

let stop = BubbleTap.action(role: "agent", text: "Hello there.", final: true, callActive: true, reading: true)
check(stop == .stop, "tap on the reading bubble stops, even mid-call")

let call = BubbleTap.action(role: "agent", text: "Hello there.", final: true, callActive: true, reading: false)
check(call == .notice("Replay is off during a call"), "call active: replay disabled")

let blank = BubbleTap.action(role: "agent", text: "  \n", final: true, callActive: false, reading: false)
check(blank == .notice("Nothing to read"), "blank text: nothing to read")

let streaming = BubbleTap.action(role: "agent", text: "Hello", final: false, callActive: false, reading: false)
check(streaming == .notice("This turn is still speaking"), "streaming turn: not replayable yet")

let caller = BubbleTap.action(role: "caller", text: "Hi back.", final: true, callActive: false, reading: false)
check(caller == .notice("No stored audio for this turn"), "caller turn: no silent substitution")

print("all ok")
