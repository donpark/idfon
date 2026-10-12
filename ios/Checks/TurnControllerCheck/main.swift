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

// EchoTrim: the agent's whole last utterance re-heard at the start is dropped.
check(
    EchoTrim.trim(
        heard: "Hello, please speak. Hi, this is Don.",
        lastSpoken: "Hello, please speak."
    ) == "Hi, this is Don.",
    "drops the whole echoed greeting"
)
check(
    EchoTrim.trim(heard: "of course. What time is it?", lastSpoken: "Of course.")
        == "What time is it?",
    "drops echo case-insensitively"
)
// A caller who repeats one word is not clipped (fail-open).
check(
    EchoTrim.trim(heard: "Tokyo is where I live", lastSpoken: "Tokyo")
        == "Tokyo is where I live",
    "does not clip a single repeated word"
)
check(
    EchoTrim.trim(heard: "what is the weather", lastSpoken: "Sure thing.")
        == "what is the weather",
    "no overlap leaves the transcript alone"
)
check(
    EchoTrim.trim(heard: "Hello, please speak.", lastSpoken: "Hello, please speak.")
        == "",
    "all-echo transcript becomes empty"
)
check(EchoTrim.trim(heard: "hello", lastSpoken: nil) == "hello", "no last spoken")

print("ALL OK")
