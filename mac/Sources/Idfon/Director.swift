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

    /// Create the on-device director with a wrapped-agent callback: its
    /// `voice_forward` tool delegates each turn to `forward` (the app forwards
    /// to the called idfon peer and blocks for the reply), so a proxy call can
    /// answer a small thing itself and hand the rest over. The caller must run
    /// the director off the main thread.
    static func createAFMWrapped(
        instructions: String,
        config: [String: Any] = [:],
        forward: idfon_director_forward_fn?,
        freeReply: idfon_director_free_fn?
    ) -> Director? {
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pointer = instructions.withCString { text in
            json.withCString { config in
                idfon_director_new_afm_wrapped(text, config, nil, forward, freeReply)
            }
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

    /// Run one multimodal turn (`TurnInput`: text, references, attachments).
    func turn(input: [String: Any]) -> [String: Any]? {
        let json = (try? JSONSerialization.data(withJSONObject: input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let pointer = json.withCString({ idfon_director_turn_input(handle, $0) }) else {
            return nil
        }
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

    /// The trace record of a turn.
    static func record(_ result: [String: Any]) -> [String: Any] {
        result["record"] as? [String: Any] ?? [:]
    }

    /// The C callback behind `voice_forward`: forward to the called peer and
    /// block until the reply arrives, then hand the host-allocated string to
    /// Rust (freed by `freeReplyCallback`).
    static let forwardCallback: idfon_director_forward_fn = {
        _, textPointer, _, outReply in
        guard let textPointer, let outReply else { return 1 }
        let text = String(cString: textPointer)
        let semaphore = DispatchSemaphore(value: 0)
        var reply: String?
        Task { @MainActor in
            reply = await VoiceAgentSession.shared.forwardToActiveAgent(text)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else { return 2 }
        guard let reply, !reply.isEmpty, let pointer = strdup(reply) else { return 3 }
        outReply.pointee = pointer
        return 0
    }

    static let freeReplyCallback: idfon_director_free_fn = { pointer in
        free(pointer)
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

/// The live-call director: one AFM director per proxy call, prewarmed at call
/// setup and run per caller turn. Enabled per contact (`VoiceTurnMode.proxy`);
/// `-directorcall` forces it on any contact as the device probe for this path.
/// A turn that fails falls back to the remote agent
/// (`VoiceAgentSession.reply`).
final class DirectorRuntime {
    static let shared = DirectorRuntime()

    private var director: Director?
    private(set) var enabled = false

    static let instructions = """
    # Identity
    You are the voice of the agent the caller reached. Never introduce yourself or say you are a voice agent, director, assistant, or middleware; never mention the pipeline, the model, or the tools. The caller believes they are talking to the agent.
    # Output rules
    Plain spoken text only. One short sentence. Never ask the caller to repeat or clarify a name they did not give.
    # Tools
    speak: say the short spoken reply.
    voice_forward: send the caller's exact words to the agent and speak its reply.
    # Routing
    A greeting, an acknowledgement, or a short answer you know: speak it. Anything else: voice_forward.
    """

    /// Prepare the director for this call (load + warm the session), off the
    /// main thread. No-op unless the contact is set to proxy mode, and when AFM
    /// is unavailable. Await it before the first turn so the model is warm.
    func startCall(proxy: Bool) async {
        guard !enabled else { return }
        let probe = ProcessInfo.processInfo.arguments.contains("-directorcall")
        guard proxy || probe else { return }
        let trace: [String: Any] = [
            "tier": "on-device", "provider": "afm", "model": "apple-foundation-models",
        ]
        let created: Director? = await Task.detached(priority: .userInitiated) { () -> Director? in
            guard let director = Director.createAFMWrapped(
                instructions: Self.instructions,
                config: ["grant": ["speak", "voice_forward"], "budget": 32, "trace": trace],
                forward: Director.forwardCallback,
                freeReply: Director.freeReplyCallback
            ) else { return nil }
            let started = Date()
            director.prewarm()
            Automation.mark("director: call prewarm_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return director
        }.value
        guard let created else {
            Automation.mark("director: call unavailable (AFM off?)")
            return
        }
        director = created
        enabled = true
        Automation.mark("director: call ready (voice_forward enabled) proxy=\(proxy) probe=\(probe)")
    }

    func endCall() {
        director = nil
        enabled = false
    }

    /// Run one caller turn on the director, off the main thread. Returns the
    /// spoken reply, or nil to fall back to the remote agent.
    func turn(_ text: String) async -> String? {
        guard let director else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                guard let result = director.turn(text) else {
                    Automation.mark("director: call FAIL turn")
                    continuation.resume(returning: nil)
                    return
                }
                let spoken = Director.spokenText(result)
                let outcome = Director.record(result)["outcome"] as? [String: Any]
                Automation.mark("director: call turn_ms=\(Int(Date().timeIntervalSince(started) * 1000)) spoken=\(spoken)")
                Automation.mark("director: call status=\(outcome?["status"] as? String ?? "?")")
                continuation.resume(returning: spoken.isEmpty ? nil : spoken)
            }
        }
    }
}
