import Foundation

/// Second-ear gate for the agent's voice feedback. A Tyger BACKCHANNEL cue
/// ("mm-hm") plays on the AEC bus like any TTS, but it must never reach the
/// turn model's agent channel — the heads were calibrated on the agent's
/// turns, not on its own backchannel — so the playback observers skip samples
/// scheduled while `suppress` is active (`docs/voice-tyger-streaming-plan.md`:
/// "a 'mm-hm' that never enters history or the second ear"). History is the
/// loop's side: VoiceAgentSession keeps the cue out of `lastSpoken`.
enum FeedbackEar {
    private static let lock = NSLock()
    private static var depth = 0

    /// True while feedback is playing: the second ear drops these samples.
    static var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    /// Run `body` with the second ear closed (nesting-safe). The lock lives in
    /// the synchronous helpers: `unlock` is unavailable from async contexts.
    static func suppress<T>(_ body: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await body()
    }

    private static func begin() {
        lock.lock()
        depth += 1
        lock.unlock()
    }

    private static func end() {
        lock.lock()
        depth -= 1
        lock.unlock()
    }
}
