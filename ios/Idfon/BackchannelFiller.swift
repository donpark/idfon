import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Contextual backchannels: the tyger-s2s filler recipe (their
/// `mouth/messages.py:bc_messages` + `session.py:stream_bc`) on the local
/// Apple Foundation Model. Given the ASR partial of the caller's turn in
/// progress, the model emits one short reaction to what they are saying (or a
/// neutral hum when there is too little to react to). Fail-open: any
/// unavailability, error, timeout, or unclean output yields nil and the
/// caller falls back to the fixed "Mm-hmm." cue.
///
/// Anti-repeat (their lesson: without it the model repeated 17% of acks): the
/// last three spoken acks go in the user line as "(You already said …)" —
/// next to the partial, where small models heed it; in the system prompt
/// their Gemma said "aw, cute!" twice on a puppy.
///
/// `-fillerscore <corpus.json>` scores this against a corpus entry's
/// backchannel moments (text-only, no audio needed).
enum BackchannelFiller {
    /// Their bc_min_words: a shorter partial is framed as "only a few words".
    static let bcMinWords = 4
    private static let recentAcksMax = 3
    // Called from both the main-thread loop and the CLI scorer; keep it
    // nonisolated (a @MainActor static would deadlock the scorer's semaphore).
    nonisolated(unsafe) private static var recentAcks: [String] = []
    private static let lock = NSLock()

    /// The tyger backchannel system prompt (config/prompts.yaml), shots folded
    /// in as examples so a single AFM call carries the whole recipe.
    private static let instructions = """
    You are a voice assistant listening to the user, who is STILL speaking. You have NOT been given the floor.
    Read their partial words so far and emit ONLY a brief, natural spoken reaction (one to four words) to WHAT
    they are saying -- match its content and emotion, for example 'oh nice', 'oh no', 'wow, really?', 'that
    makes sense', 'got it', 'right', 'sure', 'ha, yeah', 'that's great', 'oh, I see'. If they have said too
    little so far to react to, or nothing in their words calls for a specific reaction, use a neutral hum such
    as 'mm-hm' or 'mhm'. Do NOT answer, do NOT ask a real question, do NOT continue their sentence, do NOT take
    the floor. Always react in English. Plain spoken words only, no markdown or symbols. Just the short reaction.

    Examples:
    user: The user is currently saying: "I finally finished my first marathon last weekend"
    you: wow, nice!
    user: The user is currently saying: "my car broke down today right on the way to work"
    you: oh, no
    user: The user has only said a few words so far: "so I"
    you: mm-hm
    user: The user has only said a few words so far: "well so"
    you: uh-huh
    user: The user is currently saying: "I finally passed my driving test yesterday"
    you: oh, that's great!
    user: The user is currently saying: "we adopted a kitten and now the kitten sleeps on my pillow every" (You already said 'aw, how cute'.)
    you: ha, lucky you
    user: The user is currently saying: "so the flight got cancelled and then the airline lost my bag and" (You already said 'oh, no'.)
    you: ugh, what a day
    user: The user is currently saying: "I got the job, and the job is in Denver, so in Denver we'll need a" (You already said 'that's great', 'wow'.)
    you: mm-hm
    """

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// A short contextual ack for the partial, or nil (caller speaks the fixed
    /// cue). Never throws, never blocks a turn: everything is fail-open.
    static func ack(partial: String) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable, #available(iOS 26.0, macOS 26.0, *) else { return nil }
        let prompt = userLine(partial.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions
            )
            let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: 24)
            let response = try await session.respond(to: prompt, options: options)
            guard let text = normalize(response.content) else { return nil }
            // AFM can repeat despite the no_repeat line (identical partials
            // recur mid-turn). Swap a repeat for the first unused audited-safe
            // ack so variety is guaranteed, not hoped for.
            let out: String
            if recentAcksSnapshot().contains(text) {
                let fallbacks = ["Mm-hmm.", "Hmm.", "Mhm.", "Yeah.", "Right.", "Okay."]
                guard let fresh = fallbacks.first(where: { !recentAcksSnapshot().contains($0) }) else {
                    return nil
                }
                out = fresh
            } else {
                out = text
            }
            rememberAck(out)
            return out
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func rememberAck(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        recentAcks.append(text)
        if recentAcks.count > recentAcksMax {
            recentAcks.removeFirst(recentAcks.count - recentAcksMax)
        }
    }

    private static func recentAcksSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recentAcks
    }

    /// Their bc_messages user framing + the no_repeat suffix.
    private static func userLine(_ partial: String) -> String {
        let user: String
        if partial.isEmpty {
            user = "The user is speaking, but no words have been recognized yet."
        } else if partial.split(separator: " ").count < bcMinWords {
            user = "The user has only said a few words so far: \"\(partial)\""
        } else {
            user = "The user is currently saying: \"\(partial)\""
        }
        let acks = recentAcksSnapshot()
        return acks.isEmpty
            ? user
            : user + " (You already said \(acks.map { "'\($0)'" }.joined(separator: ", ")).)"
    }

    /// Their say_clean gate (nothing speakable = no ack, not remembered), plus
    /// the hum spellings that Phonon renders. "Mm-hmm." is the clean hum;
    /// "Mm-hm." phonemizes to nonsense ("lim") and "Mm." to "MAN", so bare hum
    /// forms collapse to the known-good one. Other text is passed through —
    /// shortcut: only hum spellings are normalized; a fuller TTS→ASR
    /// round-trip audit of the filler's vocabulary, when its output is varied.
    private static func normalize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\"", with: "")
        t = t.components(separatedBy: .newlines).first ?? t
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        let hums: Set<String> = ["mm-hm", "mm hmm", "mmhmm", "mm-hmm", "mhm", "mm", "uh huh", "uh-huh"]
        if hums.contains(bare) {
            return bare == "uh-huh" || bare == "uh huh" ? "Uh-huh." : "Mm-hmm."
        }
        guard t.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: - Corpus scoring

    /// Score the filler against a corpus entry's backchannel moments: at each
    /// demo `bc` time, the human's words so far are the partial; the agent's
    /// turn near that time is the demo's own ack to compare against. Prints a
    /// per-moment table and a summary. Text-only: the corpus carries timings
    /// and transcripts, no audio.
    static func runScore(path: String) {
        struct Corpus: Decodable {
            struct Turn: Decodable { let spk: Int; let s: Double; let e: Double; let text: String }
            struct Demo: Decodable { let bc: [Double] }
            struct Replay: Decodable { let demo: Demo }
            let speakers: [String: Int]
            let turns: [Turn]
            let replay: Replay
        }
        guard let data = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(Corpus.self, from: data) else {
            print("fillerscore: cannot read \(path)")
            return
        }
        let human = c.speakers["human"] ?? 1
        let agent = c.speakers["agent"] ?? 2
        print("fillerscore \(path): \(c.replay.demo.bc.count) backchannel moments")
        var acks: [String] = []
        var latencies: [Int] = []
        for t in c.replay.demo.bc {
            // Their partial = the ASR text since the last interaction: the
            // human's words after the agent's last turn, not the whole pile.
            let lastAgent = c.turns
                .filter { $0.spk == agent && $0.s < t }
                .map(\.e)
                .max() ?? -1
            let partial = c.turns
                .filter { $0.spk == human && $0.s <= t && $0.e > lastAgent }
                .map(\.text)
                .joined(separator: " ")
            let expected = c.turns.first { $0.spk == agent && abs($0.s - t) <= 0.6 }?.text ?? "—"
            let start = Date()
            let sem = DispatchSemaphore(value: 0)
            var got: String?
            Task {
                got = await ack(partial: partial)
                sem.signal()
            }
            sem.wait()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let said = got ?? "(fallback Mm-hmm.)"
            acks.append(said)
            latencies.append(ms)
            print(String(format: "  t=%6.2f  partial: %@%@",
                         t, String(partial.prefix(48)), partial.count > 48 ? "…" : ""))
            print(String(format: "             demo: %@    filler: %@  (%d ms)", expected, said, ms))
        }
        let repeats = acks.count - Set(acks).count
        let avg = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
        print("summary: \(acks.count) acks, \(Set(acks).count) distinct, \(repeats) repeats, avg latency \(avg) ms")
    }
}
