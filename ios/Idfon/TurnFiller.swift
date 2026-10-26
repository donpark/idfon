import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tool lead-ins and "still looking" lines over reply latency — the economy
/// half of the tyger-s2s filler recipe (`mouth/turns.py` `cover()` +
/// `config/prompts.yaml` `tool_leadin`/`still_looking`), on the local Apple
/// Foundation Model: while the agent works (their case is a tool call, ours is
/// any slow turn), a fast phatic line covers the dead air. Mechanical timing
/// beats prompt preambles — the line is spoken on a clock the app owns, never
/// asked of the reply model and never sent to the agent. Voice feedback only:
/// never in history, never in the second ear (FeedbackEar).
///
/// Fail-open: any unavailability, error, or unclean output yields nil and the
/// caller speaks its fixed fallback line.
enum TurnFiller {
    /// Their FILLER_GAP_S: the next "still looking" line only this long after
    /// the last line played out.
    static let fillerGap: TimeInterval = 0.8
    /// Their MAX_STILL: at most this many still-looking lines per turn (after
    /// the one lead-in).
    static let maxStill = 2
    /// Dead air before the lead-in fires. Their lead-in fires at `tool_start`
    /// (visible in-process); in the client cascade the app only sees silence,
    /// so "the turn is slow" is the trigger. Local turns land ~1.5 s, remote
    /// tool turns in seconds — the clock is set past the former.
    static let leadInAfter: TimeInterval = 2.0

    /// The wait before the next line, or nil when the cover is done (their
    /// `cover()` schedule: one lead-in, then at most `maxStill` still-lines).
    static func nextWait(saidCount: Int) -> TimeInterval? {
        if saidCount == 0 { return leadInAfter }
        return saidCount <= maxStill ? fillerGap : nil
    }

    /// One line: the lead-in (still == false) or a still-looking line. `said`
    /// is this turn's lines so far (their anti-repeat `$said` framing).
    static func line(transcript: String, said: [String], still: Bool) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable, #available(iOS 26.0, macOS 26.0, *) else { return nil }
        let prompt = userLine(transcript: transcript, said: said, still: still)
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: still ? stillInstructions : leadInInstructions
            )
            let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: 24)
            let response = try await session.respond(to: prompt, options: options)
            return normalize(response.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Their tool_leadin system prompt + shots folded in as examples (the
    /// BackchannelFiller pattern: one AFM call carries the whole recipe),
    /// widened at the top: the client cascade cannot tell a tool call from a
    /// slow model, so the line must fit either.
    private static let leadInInstructions = """
    You are a voice assistant and you are still working on what the user asked -- looking something up for them or
    thinking your answer through. Say ONE short, natural spoken sentence that tells them you are on it, naming the
    specific thing they asked about. Do NOT answer the question, do NOT mention tools or say the word tool, do NOT
    ask anything. Speak English. Plain spoken words only, at most about ten words.

    Examples:
    user: The user asked: \"what time is it in Cape Town right now?\"
    you: Let me check the time in Cape Town.
    user: The user asked: \"remind me to call the dentist at four\"
    you: Setting a reminder about the dentist.
    user: The user asked: \"what time is it in Irkutsk?\"
    you: Let me look up the time in Irkutsk.
    user: The user asked: \"text Pablo that I'm leaving now\"
    you: Writing to Pablo now.
    user: The user asked: \"what time is it in Tokyo?\"
    you: One moment, checking the time in Tokyo.
    """

    /// Their still_looking system prompt + shots.
    private static let stillInstructions = """
    You are a voice assistant. You are looking something up for the user and it is taking a moment longer. Say
    ONE very short, natural spoken sentence that you're still on it, tied to what they asked. Do NOT repeat or
    rephrase what you already said, do NOT answer the question, do NOT mention tools. Speak English. Plain spoken
    words only, at most about eight words.

    Examples:
    user: The user asked: \"what time is it in Cape Town right now?\". You already said: 'Let me check the time in Cape Town.'
    you: Still getting the time for Cape Town.
    user: The user asked: \"remind me to call the dentist at four\". You already said: 'Setting a reminder about the dentist.'
    you: Still setting up that dentist reminder.
    user: The user asked: \"what time is it in Irkutsk?\". You already said: 'Let me look up the time in Irkutsk.'
    you: Irkutsk's time is still loading.
    """

    /// Their `tool_leadin`/`still_looking` user templates (`messages.py`
    /// `still_user`): the request, plus what was already said for a still line.
    static func userLine(transcript: String, said: [String], still: Bool) -> String {
        let asked = "The user asked: \"\(transcript)\""
        guard still else { return asked }
        let saidPart = said.isEmpty
            ? "nothing yet"
            : said.map { "'\($0)'" }.joined(separator: ", ")
        return asked + ". You already said: " + saidPart
    }

    /// Their say_clean gate (nothing speakable = no line). Line-level only:
    /// shortcut: no TTS→ASR round-trip audit of the lead-in vocabulary yet.
    static func normalize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\"", with: "")
        t = t.components(separatedBy: .newlines).first ?? t
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
