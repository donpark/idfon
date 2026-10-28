import AppKit

/// Download approval gate for the voice models (2026-10-27 rule, mac parity
/// with iOS `VoiceModelGate`): model downloads start only after the user
/// approves them on a leading action (opening a chat) — never while a call is
/// starting. Every silent downloader checks `approved` first. The turn tier is
/// not gated here: the mac loads it from the checkout's `bench-results` (or
/// the MLX bundle) — there is nothing to download.
///
/// `shortcut: pocket TTS can still pull its own models on a cold call (load
/// and download are coupled), gate it if it becomes a default.`
enum VoiceModelGate {
    private static let approvedKey = "voiceModelGate.approved"

    /// Set when the user approves; persisted so later sessions resume the
    /// downloads quietly.
    static var approved: Bool {
        get { UserDefaults.standard.bool(forKey: approvedKey) }
        set { UserDefaults.standard.set(newValue, forKey: approvedKey) }
    }

    /// Is the voice-agent's ASR on disk? `shortcut: only the default
    /// (nemotron) cache is checkable — parakeet's FluidAudio cache has no
    /// cheap presence probe; its downloader is gate-guarded either way.`
    @MainActor
    static func asrReady() -> Bool {
        switch SpeechEngines.asrBackend {
        case .nemotron:
            let dir = NemotronStreamingAsr.modelDirectory()
            return !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
        case .parakeet, .system:
            return true
        }
    }

    /// A voice-agent call may start: models are present and no download can
    /// surprise it mid-call.
    @MainActor
    static func callReady() -> Bool { approved && asrReady() }

    /// The approval gate on a leading action. Approved and ready → no-op;
    /// approved but incomplete → resume quietly (unless the caller is a call
    /// attempt — then say so); never approved → the alert.
    @MainActor
    static func prompt(forCall: Bool = false) {
        if approved {
            if asrReady() { return }
            start()
            if forCall {
                runAlert(
                    title: "Voice models downloading",
                    message: "The on-device voice models are still downloading in the background. Calls are ready when the download finishes.")
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Voice models"
        alert.informativeText = "Voice calls need on-device models: speech recognition and the reply voice. Download them in the background now? You can keep using the app; calls are ready when it finishes."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            approved = true
            start()
        }
    }

    /// Resume the approved downloads (app launch); no-op until approved.
    @MainActor
    static func resume() {
        if approved { start() }
    }

    /// Start the background downloads (the speech engines' warm caches).
    @MainActor
    static func start() {
        guard approved else { return }
        SpeechEngines.prewarm()
    }

    @MainActor
    private static func runAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
