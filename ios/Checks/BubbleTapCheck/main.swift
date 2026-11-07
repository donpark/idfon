// BubbleTapCheck: the spoken-bubble tap decision (#202), run as
// `swiftc -o /tmp/bubbletapcheck <app>/BubbleTap.swift <app>/Checks/BubbleTapCheck/main.swift && /tmp/bubbletapcheck`.
// Covers the seven decisions: stop-the-reading-bubble, the call guard, blank
// text, a streaming turn, the caller turn without audio (no silent
// substitution), the caller turn with stored audio (P2), and play (an agent
// turn plays with or without stored exact audio — exact first, else synth).

import Foundation

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok  \(what)")
    } else {
        print("FAIL \(what)")
        exit(1)
    }
}

let play = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                            callActive: false, reading: false, audioAvailable: false)
check(play == .play, "agent turn plays (synth when no stored audio)")

let playExact = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                                 callActive: false, reading: false, audioAvailable: true)
check(playExact == .play, "agent turn plays (exact when stored)")

let stop = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                            callActive: true, reading: true, audioAvailable: true)
check(stop == .stop, "tap on the reading bubble stops, even mid-call")

let call = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                            callActive: true, reading: false, audioAvailable: true)
check(call == .notice("Replay is off during a call"), "call active: replay disabled")

let blank = BubbleTap.action(role: "agent", text: "  \n", final: true,
                             callActive: false, reading: false, audioAvailable: true)
check(blank == .notice("Nothing to read"), "blank text: nothing to read")

let streaming = BubbleTap.action(role: "agent", text: "Hello", final: false,
                                 callActive: false, reading: false, audioAvailable: true)
check(streaming == .notice("This turn is still speaking"), "streaming turn: not replayable yet")

let caller = BubbleTap.action(role: "caller", text: "Hi back.", final: true,
                              callActive: false, reading: false, audioAvailable: false)
check(caller == .notice("No stored audio for this turn"), "caller turn without audio: no silent substitution")

let callerOriginal = BubbleTap.action(role: "caller", text: "Hi back.", final: true,
                                      callActive: false, reading: false, audioAvailable: true)
check(callerOriginal == .play, "caller turn with stored audio plays the original")

print("all ok")
