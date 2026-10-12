import CIdfon
import Foundation

/// The on-device conversation director (`crates/idfon-director`): the
/// voice-agent loop over Apple Foundation Models
/// (`docs/voice-agent-loop-contract.md`).
///
/// One director per on-device agent, created on first use and kept warm
/// (`OnDeviceAgentRunner`); all work runs off the main thread, since `turn`
/// blocks. A null handle means AFM is unavailable (OS floor / Apple
/// Intelligence off), so the turn fails and the caller reports it.
///
/// The mac app has no proxy director: an on-device agent answers locally, and
/// every other contact is a passive remote call (`docs/voice-agent-modes.md`).
final class Director {
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    /// Create the on-device director with a JSON config:
    /// `grant` (tool names the capability grant permits), `budget`,
    /// `trace` (tier/provider/model), `redaction`.
    static func createAFM(instructions: String, config: [String: Any] = [:]) -> Director? {
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pointer = instructions.withCString { text in
            json.withCString { config in idfon_director_new_afm_config(text, config) }
        }
        guard let pointer else { return nil }
        return Director(handle: pointer)
    }

    func prewarm() {
        _ = idfon_director_prewarm(handle)
    }

    /// Run one typed turn. Returns the `TurnResult` object (envelopes + trace
    /// record), or nil on failure.
    func turn(_ text: String) -> [String: Any]? {
        guard let pointer = text.withCString({ idfon_director_turn(handle, $0) }) else { return nil }
        defer { idfon_director_free_string(pointer) }
        return Self.object(String(cString: pointer))
    }

    deinit {
        idfon_director_free(handle)
    }

    /// Fully on-device persona: the AFM loop IS the assistant. No tools, no
    /// network; it answers from what it knows (`docs/voice-agent-modes.md`).
    static let onDeviceInstructions = """
    # Identity
    You are the voice assistant the caller is talking to, running fully on this device. Never introduce yourself as a voice agent, director, model, or assistant; never mention the pipeline or the device.
    # Output rules
    Plain spoken text only. One or two short sentences. No markdown, lists, headings, emoji, or digits. Answer first.
    # Tools
    speak: say the short spoken reply.
    # Routing
    Answer the caller directly. When you do not know, or it needs live data or an action you cannot take, say so in one short sentence.
    """
}

// The handle is used from one background queue (OnDeviceAgentRunner), one turn
// at a time, so sharing it across that queue is safe.
extension Director: @unchecked Sendable {
    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// The `IDFON-*/1` envelopes a turn emitted.
    static func envelopes(_ result: [String: Any]) -> [String] {
        result["envelopes"] as? [String] ?? []
    }

    /// The spoken text of a turn: the first `IDFON-SPEAK/1` envelope.
    static func spokenText(_ result: [String: Any]) -> String {
        let prefix = "IDFON-SPEAK/1\n"
        for envelope in envelopes(result) where envelope.hasPrefix(prefix) {
            let body = String(envelope.dropFirst(prefix.count))
            if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
               let text = object["text"] as? String, !text.isEmpty {
                return text
            }
        }
        return ""
    }
}
