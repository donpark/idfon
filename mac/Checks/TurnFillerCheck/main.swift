// Runnable check for `TurnFiller` (not part of the app target).
// TurnFiller is Foundation-only where it counts (the AFM path is never
// exercised here), so this runs on the host with plain swiftc:
//
//   swiftc -o /tmp/tfcheck mac/Sources/Idfon/TurnFiller.swift \
//     mac/Checks/TurnFillerCheck/main.swift
//   /tmp/tfcheck
//
// The cases are tyger-s2s's filler-economy invariants (mouth/turns.py
// cover() + config/prompts.yaml tool_leadin/still_looking + messages.py
// still_user). Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) }
}

// The cover schedule: one lead-in after the dead-air clock, then at most
// MAX_STILL still-lines at FILLER_GAP_S each, then done.
check(TurnFiller.nextWait(saidCount: 0) == TurnFiller.leadInAfter, "lead-in waits the dead-air clock")
check(TurnFiller.nextWait(saidCount: 1) == TurnFiller.fillerGap, "first still waits the filler gap")
check(TurnFiller.nextWait(saidCount: 2) == TurnFiller.fillerGap, "second still waits the filler gap")
check(TurnFiller.nextWait(saidCount: 3) == nil, "cover ends after the lead-in + MAX_STILL")
check(TurnFiller.maxStill == 2, "MAX_STILL is 2 (theirs)")

// User framing: the lead-in sees the request only (their tool_leadin `user`).
do {
    let line = TurnFiller.userLine(transcript: "what time is it in Tokyo?", said: [], still: false)
    check(line == "The user asked: \"what time is it in Tokyo?\"", "lead-in framing: \(line)")
}

// Still framing carries what was already said (their `still_user` $said).
do {
    let line = TurnFiller.userLine(
        transcript: "what time is it in Tokyo?",
        said: ["Let me check the time in Tokyo."], still: true)
    check(line.hasSuffix("You already said: 'Let me check the time in Tokyo.'"),
          "still framing carries $said: \(line)")
    let two = TurnFiller.userLine(
        transcript: "the weather in Lisbon",
        said: ["Let me pull up the forecast.", "Still on it."], still: true)
    check(two.hasSuffix("You already said: 'Let me pull up the forecast.', 'Still on it.'"),
          "$said is a comma list: \(two)")
    let none = TurnFiller.userLine(transcript: "hi", said: [], still: true)
    check(none.hasSuffix("You already said: nothing yet"), "empty $said is 'nothing yet': \(none)")
}

// Their say_clean gate: nothing speakable yields no line; quotes and
// multi-line output collapse to one spoken sentence.
check(TurnFiller.normalize("   \"Still getting the time for Cape Town.\"   ") == "Still getting the time for Cape Town.",
      "quotes stripped + trimmed")
check(TurnFiller.normalize("Still on it.\nExtra markdown line") == "Still on it.", "first line only")
check(TurnFiller.normalize("... ") == nil, "nothing speakable yields nil")
check(TurnFiller.normalize("let me check the time in Tokyo.") == "Let me check the time in Tokyo.",
      "sentence capitalized")

// Hum policy: Phonon sounds letter strings out as words ("mm-hm" is heard as
// "lim", "mm" as "meem"), so bare vocalizations never reach the mouth and
// leading ones are stripped from the line.
check(TurnFiller.normalize("Mm-hmm.") == nil, "bare hum yields no line")
check(TurnFiller.normalize("hmm") == nil, "bare 'hmm' yields no line")
check(TurnFiller.normalize("Um, let me check the time in Tokyo.") == "Let me check the time in Tokyo.",
      "leading 'um' stripped")
check(TurnFiller.normalize("Hmm. Still getting the time for Cape Town.") == "Still getting the time for Cape Town.",
      "leading hum dropped with the rest kept")
check(TurnFiller.isVocalization("Mm-hm."), "mm-hm is a vocalization")
check(!TurnFiller.isVocalization("yeah"), "a word is not a vocalization")

print("ALL OK")
