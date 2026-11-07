// BubbleTapCheck: the spoken-bubble tap decision (#202), run as
// `swiftc -o /tmp/bubbletapcheck <app>/BubbleTap.swift <app>/Checks/BubbleTapCheck/main.swift && /tmp/bubbletapcheck`.
// Covers the decisions: stop-the-reading-bubble, the call guard, blank text,
// a streaming turn, the caller turn with nothing (no silent substitution),
// the caller turn with stored audio (P2), the caller turn with only a clone
// voice (P3 opt-in), and play (agent turns: exact when stored, else synth).

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
                            callActive: false, reading: false,
                            audioAvailable: false, cloneVoiceAvailable: false)
check(play == .play, "agent turn plays (synth when no stored audio)")

let playExact = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                                 callActive: false, reading: false,
                                 audioAvailable: true, cloneVoiceAvailable: true)
check(playExact == .play, "agent turn plays (exact when stored)")

let stop = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                            callActive: true, reading: true,
                            audioAvailable: true, cloneVoiceAvailable: true)
check(stop == .stop, "tap on the reading bubble stops, even mid-call")

let call = BubbleTap.action(role: "agent", text: "Hello there.", final: true,
                            callActive: true, reading: false,
                            audioAvailable: true, cloneVoiceAvailable: true)
check(call == .notice("Replay is off during a call"), "call active: replay disabled")

let blank = BubbleTap.action(role: "agent", text: "  \n", final: true,
                             callActive: false, reading: false,
                             audioAvailable: true, cloneVoiceAvailable: true)
check(blank == .notice("Nothing to read"), "blank text: nothing to read")

let streaming = BubbleTap.action(role: "agent", text: "Hello", final: false,
                                 callActive: false, reading: false,
                                 audioAvailable: true, cloneVoiceAvailable: true)
check(streaming == .notice("This turn is still speaking"), "streaming turn: not replayable yet")

let caller = BubbleTap.action(role: "caller", text: "Hi back.", final: true,
                              callActive: false, reading: false,
                              audioAvailable: false, cloneVoiceAvailable: false)
check(caller == .notice("No stored audio for this turn"), "caller turn with nothing: no silent substitution")

let callerOriginal = BubbleTap.action(role: "caller", text: "Hi back.", final: true,
                                      callActive: false, reading: false,
                                      audioAvailable: true, cloneVoiceAvailable: false)
check(callerOriginal == .play, "caller turn with stored audio plays the original")

let callerClone = BubbleTap.action(role: "caller", text: "Hi back.", final: true,
                                   callActive: false, reading: false,
                                   audioAvailable: false, cloneVoiceAvailable: true)
check(callerClone == .play, "caller turn with only a clone voice plays (P3 opt-in)")

print("all ok")
