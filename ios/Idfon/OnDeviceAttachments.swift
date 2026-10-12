import Foundation

/// Files an app-local agent can be given.
///
/// The local model has no `ReferenceResolver` and no sandbox: the loop renders
/// the turn, and the only attachment whose content it can actually show is
/// text. So a text file is read here and inlined into the turn, and any other
/// file is refused rather than quietly dropped
/// (`docs/voice-multimodal.md`).
enum OnDeviceAttachments {
    /// Read cap. A picked file can be arbitrarily large; the model prompt
    /// cannot, and the loop bounds it again as a backstop
    /// (`MAX_TEXT_ATTACHMENT_BYTES` in `crates/idfon-director`).
    static let maxTextBytes = 32 * 1024

    /// Read `url` as UTF-8 text, capped at `maxBytes`. Nil when the file is
    /// binary, empty, or unreadable — the caller reports that instead of
    /// sending a turn with nothing in it.
    static func text(at url: URL, maxBytes: Int = maxTextBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Reading up to the cap can cut a multi-byte character in half: drop
        // the partial tail (at most 3 bytes in UTF-8) and decode again.
        for dropped in 1...3 where data.count > dropped {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        return nil
    }

    /// The `TurnInput` for a file turn: the caller's turn text plus the file as
    /// an inline attachment, so the loop renders both into one prompt and keeps
    /// the content inside its untrusted-data block.
    static func turnInput(text: String, name: String, content: String) -> [String: Any] {
        [
            "text": text,
            "attachments": [
                ["kind": "text", "name": promptName(name), "content": content],
            ],
        ]
    }

    /// The name as the model sees it. Newlines would let a file name break out
    /// of the `[file] <name>` label the loop renders.
    static func promptName(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
