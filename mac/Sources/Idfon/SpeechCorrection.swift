import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional post-ASR cleanup using the local Apple Foundation Model.
///
/// Fixes minor spelling/grammar/punctuation and obvious misheard words without
/// changing the speaker's meaning — the same idea as Ghost Pepper's local LLM
/// cleanup, but the on-device system model instead of a bundled one, so there
/// is no extra download or memory. Fail-open: any unavailability, error,
/// timeout, or implausible output yields the raw transcript unchanged.
///
/// Off by default (it adds model latency before each prompt); enable with
/// `IDFON_ASR_CORRECTION=1` or the `-asrcorrect 1` launch arg.
enum SpeechCorrection {
    private static let instructions = """
    You clean up a speech-recognition transcript. Fix only spelling, grammar, \
    punctuation, and obvious homophone or misheard-word errors. Preserve the \
    speaker's wording and meaning exactly: do not add, remove, answer, \
    summarize, translate, or rephrase content. Keep filler words unless they \
    are clearly a recognition error. Return only the corrected transcript, \
    with no quotation marks, labels, or commentary.
    """

    /// Whether cleanup runs. Off unless explicitly enabled, so the default
    /// voice loop stays as responsive as it was before this step existed.
    static var isEnabled: Bool {
        explicitSetting ?? false
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Returns the cleaned transcript, or `text` unchanged when cleanup is off,
    /// unavailable, times out, errors, or the model's output looks untrustworthy.
    static func correct(_ text: String, timeout: Duration = .seconds(4)) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(FoundationModels)
        guard isEnabled, !trimmed.isEmpty, isAvailable else { return text }
        guard #available(iOS 26.0, macOS 26.0, *) else { return text }
        let task = Task<String?, Never> {
            do {
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    instructions: instructions
                )
                let options = GenerationOptions(
                    temperature: 0,
                    maximumResponseTokens: min(1024, max(64, trimmed.count / 2))
                )
                let response = try await session.respond(to: trimmed, options: options)
                return response.content
            } catch {
                return nil
            }
        }
        let candidate = await withTaskGroup(of: String?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                task.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return sanitize(candidate, original: trimmed) ?? text
        #else
        return text
        #endif
    }

    private static var explicitSetting: Bool? {
        if let value = ProcessInfo.processInfo.environment["IDFON_ASR_CORRECTION"] {
            return parse(value)
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-asrcorrect"), args.count > index + 1 {
            return parse(args[index + 1])
        }
        return nil
    }

    private static func parse(_ value: String) -> Bool {
        !["0", "off", "false", "no"].contains(value.lowercased())
    }

    /// Rejects runaway, refusal, or chatty outputs: must be non-empty, similar
    /// in length to the input, and not start with model commentary.
    private static func sanitize(_ candidate: String?, original: String) -> String? {
        guard var value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        let preambles = [
            "here is", "here's", "sure,", "certainly", "of course",
            "corrected transcript", "transcript:", "cleaned up",
        ]
        if preambles.contains(where: { lower.hasPrefix($0) }) { return nil }
        let ratio = Double(value.count) / Double(max(1, original.count))
        guard ratio >= 0.5, ratio <= 1.8 else { return nil }
        return value
    }
}
