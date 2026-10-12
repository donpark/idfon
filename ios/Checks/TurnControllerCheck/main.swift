// Runnable check for `TurnController` (not part of the Xcode target).
// Foundation-only, so it compiles and runs on the host:
//
//   swiftc -o /tmp/tccheck ios/Idfon/TurnController.swift \
//     ios/Checks/TurnControllerCheck/main.swift && /tmp/tccheck
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL:", message); exit(1) }
    print("ok:", message)
}

// Backchannels are ignored.
check(TurnController.decide(transcript: "mm-hmm") == .ignoreBackchannel, "mm-hmm")
check(TurnController.decide(transcript: "mm hmm") == .ignoreBackchannel, "mm hmm")
check(TurnController.decide(transcript: "uh-huh") == .ignoreBackchannel, "uh-huh")
check(TurnController.decide(transcript: "Yeah") == .ignoreBackchannel, "yeah, case-insensitive")
check(TurnController.decide(transcript: "hmm.") == .ignoreBackchannel, "hmm with punctuation")
check(TurnController.decide(transcript: "got it") == .ignoreBackchannel, "got it")

// Requests and answers are forwarded (fail-open).
check(TurnController.decide(transcript: "what is the weather in Tokyo?") == .forward, "question")
check(TurnController.decide(transcript: "yes") == .forward, "yes is an answer, not a noise")
check(TurnController.decide(transcript: "okay") == .forward, "okay is an answer, not a noise")
check(TurnController.decide(transcript: "sure") == .forward, "sure is ambiguous, forward")
check(TurnController.decide(transcript: "remind me at noon") == .forward, "imperative")
check(TurnController.decide(transcript: "") == .forward, "empty forwards (fail-open)")
check(TurnController.decide(transcript: "yeah what time is it") == .forward, "noise plus a request")

print("ALL OK")
