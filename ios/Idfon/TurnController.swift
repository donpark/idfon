import Foundation

/// Deterministic turn policy for the passive voice path: no LLM sits in front
/// of the content. It decides whether a finished transcript is a request to
/// forward to the wrapped agent, or a backchannel to ignore.
///
/// Fail-open: anything not clearly a backchannel is forwarded, so a misread
/// costs a normal turn, never a dropped request. `-turncontroller` enables it
/// (prototype; see `docs/voice-passive-mode.md`).
enum TurnController {
    enum Decision: Equatable {
        case forward
        case ignoreBackchannel
    }

    /// Whole-utterance acknowledgements (matched on the normalized string).
    private static let phrases: Set<String> = [
        "mm hmm", "uh huh", "got it", "i see", "you bet", "for sure",
    ]

    /// Single acknowledgement noises. Deliberately narrow: "yes", "no", "okay"
    /// and "sure" can be real answers, so they are forwarded.
    private static let noises: Set<String> = [
        "mm", "hmm", "hm", "mhm", "mmhmm", "uhhuh", "yeah", "yep", "yup", "uh",
    ]

    /// Cues that make a short utterance a request even if it contains a noise.
    private static let requestCues = [
        "?", "what", "when", "where", "who", "why", "how", "which", "weather",
        "can you", "could you", "would you", "tell ", "show ", "find", "look up",
        "remind", "set ", "add ", "send ", "call ", "play ", "open ", "search",
        "please", "help",
    ]

    static func decide(transcript: String) -> Decision {
        // Hyphens and runs of whitespace become one space, so "mm-hmm" and
        // "MM  HMM" match the phrase set.
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return .forward }

        for cue in requestCues where normalized.contains(cue) {
            return .forward
        }
        if phrases.contains(normalized) {
            return .ignoreBackchannel
        }
        let words = normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        if words.count == 1, noises.contains(words[0]) {
            return .ignoreBackchannel
        }
        return .forward
    }
}
