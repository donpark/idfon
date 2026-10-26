import Foundation

/// Streaming sentence/clause chunker + sanitizer: the wholesale port of
/// tyger-s2s's `mouth/chunker.py` (docs/voice-tyger-streaming-plan.md phase 4).
/// As reply text arrives (whole today; deltas later), cut at sentence
/// boundaries and hand each chunk to the mouth as it closes, so playback can
/// start on chunk 1 while the rest renders. Their `first_chunk` choice is
/// `sentence` (user-tested better than `clause`): `nextChunk(_, first: false)`
/// throughout; the `first` machinery stays for parity.
///
/// Checked by `mac/Checks/SpeechChunkerCheck` (their boundary cases:
/// 0.50 / 3,000 / 1:30 / example.com / Las-Palmas / J. K. Rowling / U.S.).
enum SpeechChunker {
    /// Never cut a chunk shorter than this: short replies/sentences go out
    /// whole (merged with what follows).
    static let minChars = 40    /// First-chunk fallback when the rule is `clause`: cut at a word boundary
    /// after this many words.
    static let firstMaxWords = 12
    /// Later chunks are whole sentences; a run-on still flushes at this many
    /// chars on a space.
    static let sentMax = 220

    private static let strong: Set<Character> = [".", "!", "?", "…"]
    private static let weak: Set<Character> = [",", ";", ":", "—", "–"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "»", "”", "’"]
    /// A "." after these (lower-cased, without the dot) is not a sentence end.
    private static let abbrev: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "approx", "mt", "ft", "no", "fig",
    ]

    // MARK: - say_clean (the mouth has no paralinguistic tags)

    /// Keep letters, digits, whitespace and basic speakable punctuation;
    /// strip markdown/symbols/emoji. Clause dashes become commas (a pause
    /// cue) except digit ranges ("5 – 10" -> "5-10").
    static func sayClean(_ text: String) -> String {
        var s = dashToComma(text)
        var kept = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch.isWhitespace
                || ".,!?;:'’‘ʼ`´\"“”()\u{2D}$%".contains(ch) {
                kept.append(ch)
            } else {
                kept.append(" ")
            }
        }
        s = kept.replacingOccurrences(of: "_", with: " ")
        // Squeeze whitespace; drop spaces and commas directly before
        // punctuation (their `\s+([.,!?;:])` and `,(?=[,.!?;:])` passes).
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var tight = ""
        let chars = Array(s)
        for (idx, ch) in chars.enumerated() {
            if ch.isWhitespace || ch == ",",
               let next = chars[(idx + 1)...].first(where: { !$0.isWhitespace }),
               ".,!?;:".contains(next) {
                continue
            }
            tight.append(ch)
        }
        return tight.trimmingCharacters(in: .whitespaces)
            .trimmingPrefix(",")
            .trimmingCharacters(in: .whitespaces)
            .description
    }

    /// `\s*[—–]\s*` or `\s+-(\s+|$)` -> ", "; digit on both sides keeps a
    /// hyphen (a range, not a clause dash).
    private static func dashToComma(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let spacedHyphen = ch == "-" && i > 0 && chars[i - 1].isWhitespace
                && (i + 1 == chars.count || chars[i + 1].isWhitespace)
            if ch == "—" || ch == "–" || spacedHyphen {
                while out.last?.isWhitespace == true { out.removeLast() } // \s* before
                let left = out.last.map(String.init) ?? ""
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 } // \s* after
                let right = j < chars.count ? String(chars[j]) : ""
                if left.rangeOfCharacter(from: .decimalDigits) != nil
                    && right.rangeOfCharacter(from: .decimalDigits) != nil {
                    out.append("-") // "5 – 10": a range
                } else {
                    out.append(", ")
                }
                i = max(j, i + 1)
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    // MARK: - streaming chunker

    /// A "." at `dot` is an abbreviation/acronym ("U.S.", "e.g.", "J.").
    private static func isAbbrev(_ core: [Character], _ dot: Int) -> Bool {
        var start = 0
        for k in stride(from: dot, through: 0, by: -1) where core[k] == " " || core[k] == "\n" {
            start = k + 1
            break
        }
        var tok = String(core[start...dot])
        while let first = tok.first, "\"'([«“‘".contains(first) { tok.removeFirst() }
        if !tok.isEmpty, tok.allSatisfy({ $0 == "." || $0.isLetter || $0.isNumber }) {
            let dots = tok.filter { $0 == "." }.count
            if dots > 1 { return true } // "U.S." / "e.g."
        }
        return abbrev.contains(String(tok.dropLast()).lowercased())
    }

    /// Confirmed boundaries: `(end, strong)` — `core[..<end]` is the chunk
    /// including punctuation/closers. A boundary only counts once the next
    /// char is known to be whitespace, so "0.50", "3,000", "1:30",
    /// "example.com" never split.
    private static func boundaries(_ core: [Character]) -> [(end: Int, strong: Bool)] {
        var found: [(Int, Bool)] = []
        let n = core.count
        var i = 0
        while i < n {
            let ch = core[i]
            let spacedHyphen = ch == "-" && i > 0 && core[i - 1] == " "
            if (spacedHyphen || ch == "–"), core[..<i].last.map({ $0.isNumber }) ?? false {
                i += 1
                continue // "5 - 10": a range
            }
            if strong.contains(ch) || weak.contains(ch) || spacedHyphen {
                var j = i
                while j + 1 < n, strong.contains(core[j + 1]) || closers.contains(core[j + 1]) { j += 1 }
                if j + 1 < n, core[j + 1].isWhitespace {
                    let isStrong = core[i...j].contains { strong.contains($0) }
                    if !(ch == "." && j == i && isAbbrev(core, i)) {
                        found.append((j + 1, isStrong))
                    }
                }
                i = j + 1
                continue
            }
            i += 1
        }
        return found
    }

    /// Index just past the `maxWords`-th complete word (one already followed
    /// by whitespace), else nil.
    private static func wordCut(_ core: [Character], _ maxWords: Int) -> Int? {
        var words = 0
        var i = 0
        while i < core.count {
            if !core[i].isWhitespace, i + 1 < core.count, core[i + 1].isWhitespace {
                words += 1
                if words >= maxWords { return i + 1 }
            }
            i += 1
        }
        return nil
    }

    /// `(chunk, rest)` when a chunk is ready to speak, else nil. Operates on
    /// the unsanitized tail; callers sanitize at the mouth.
    static func nextChunk(_ pending: String, first: Bool = false) -> (chunk: String, rest: String)? {
        let lead = pending.prefix { $0.isWhitespace }.count
        let core = Array(pending.dropFirst(lead))
        if core.isEmpty { return nil }
        for (end, isStrong) in boundaries(core) {
            if !first, end > sentMax { break }
            if String(core[..<end]).trimmingCharacters(in: .whitespaces).count >= minChars,
               isStrong || first {
                return (String(core[..<end]).trimmingCharacters(in: .whitespaces),
                        String(core[end...]))
            }
        }
        if first {
            if let cut = wordCut(core, firstMaxWords) {
                return (String(core[..<cut]).trimmingCharacters(in: .whitespaces),
                        String(core[cut...]))
            }
        } else if core.count >= sentMax {
            var cut = sentMax
            if let space = core[..<sentMax].lastIndex(of: " "), space > sentMax / 2 { cut = space }
            return (String(core[..<cut]).trimmingCharacters(in: .whitespaces),
                    String(core[cut...]))
        }
        return nil
    }

    /// Drain a whole reply into sentence chunks (the tail flushes whole —
    /// their `Mouth._flush_tail`).
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var rest = text
        while let (chunk, tail) = nextChunk(rest) {
            out.append(chunk)
            rest = tail
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}

/// Incremental mouth feed over a growing text (the speech-unit `partial`
/// stream, `docs/voice-agent-loop-contract.md` §2): holds the unspoken tail
/// and yields whole chunks as they close, so playback starts on chunk 1 while
/// the rest still renders. `finish` closes with the tail. If the stream
/// diverges (a speak envelope's spoken form can differ from the body that
/// streamed first), `finish` yields the final text whole — fail-open to the
/// pre-streaming behavior.
struct ChunkFeeder {
    /// Everything accepted from the stream so far.
    private(set) var fed = ""
    private var pending = ""
    private var broken = false

    /// Feed the newest cumulative snapshot; returns the chunks that closed.
    mutating func feed(_ cumulative: String) -> [String] {
        guard !broken else { return [] }
        guard cumulative.hasPrefix(fed) else {
            // Diverged: stop feeding the mouth; `finish` speaks the final
            // text whole (already-spoken chunks were phatic-at-worst).
            broken = true
            pending = ""
            return []
        }
        pending += String(cumulative.dropFirst(fed.count))
        fed = cumulative
        return drain()
    }

    /// Close the unit with its authoritative full form; returns everything
    /// left to speak.
    mutating func finish(_ final: String) -> [String] {
        if !broken && final.hasPrefix(fed) {
            pending += String(final.dropFirst(fed.count))
        } else {
            pending = final
        }
        fed = final
        broken = true // the unit is closed; further feeds are ignored
        var out = drain()
        let tail = pending.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(SpeechChunker.sayClean(tail)) }
        pending = ""
        return out
    }

    private mutating func drain() -> [String] {
        var out: [String] = []
        while let next = SpeechChunker.nextChunk(pending, first: false) {
            out.append(SpeechChunker.sayClean(next.chunk))
            pending = next.rest
        }
        return out
    }
}
