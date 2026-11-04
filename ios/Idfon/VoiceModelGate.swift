import TygerVoiceCoreAI
import UIKit

/// Download approval gate for the voice/turn models (2026-10-27 rule): model
/// downloads start only after the user approves them on a leading action
/// (opening a callable chat) — never while a call is starting. Every silent
/// downloader checks `approved` first, so no call path (UI, incoming, or the
/// `-dial`/`-voiceagent` automation channel) can cold-pull a model mid-setup.
///
/// `shortcut: the phonon TTS pack can still download on a cold call (load
/// and download are coupled), gate it when it matters.`
enum VoiceModelGate {
    private static let approvedKey = "voiceModelGate.approved"

    /// Set when the user approves; persisted so later sessions resume the
    /// downloads quietly.
    static var approved: Bool {
        get { UserDefaults.standard.bool(forKey: approvedKey) }
        set { UserDefaults.standard.set(newValue, forKey: approvedKey) }
    }

    /// Is the voice-agent's ASR on disk? `shortcut: only the default
    /// (nemotron) cache is checkable — FluidAudio's parakeet cache has no
    /// cheap presence probe; its downloader is gate-guarded either way.`
    @MainActor
    static func asrReady() -> Bool {
        switch SpeechEngines.asrBackend {
        case .nemotron:
            let dir = NemotronStreamingAsr.modelDirectory()
            return !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
        case .system:
            return true
        }
    }

    /// The turn tier on disk (either rung loads; classic turn-taking works
    /// without it, so this never blocks a call — it only drives the resume).
    static func turnTierReady() -> Bool {
        let dir = TygerModelStore.root
        let fm = FileManager.default
        if #available(iOS 27.0, *) {
            let coreai = dir.appendingPathComponent("coreai")
            // Loadable = files + AOT container this OS accepts (`select`). A
            // student step also needs its per-model traits (a 183-byte resume
            // fetch; without this the calibrated knobs never land on upgrade).
            if CoreAITurnModel.loadable(in: coreai) {
                let student = CoreAITurnModel.studentStep(in: coreai)
                if !student || CoreAITurnModel.hasTraits(in: coreai) { return true }
            }
        }
        let present = { (name: String) in fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        guard present("TygerEncoder.mlpackage"), present("TygerEncoderDyn.mlpackage") else { return false }
        return present("StudentStep.mlpackage") ? present("student.traits.json") : present("TygerStep.mlpackage")
    }

    /// A voice-agent call may start: models are present and no download can
    /// surprise it mid-call.
    @MainActor
    static func callReady() -> Bool { approved && asrReady() }

    /// The approval gate on a leading action. Approved and ready → no-op;
    /// approved but incomplete → resume the downloads quietly (unless the
    /// caller is a call attempt — then say so); never approved → the alert.
    @MainActor
    static func prompt(from vc: UIViewController, asr: String? = nil, tts: String? = nil, forCall: Bool = false) {
        if approved {
            if asrReady() && turnTierReady() { return }
            start(asr: asr, tts: tts)
            if forCall {
                let alert = UIAlertController(
                    title: "Voice models downloading",
                    message: "The on-device voice models are still downloading in the background. Calls are ready when the download finishes.",
                    preferredStyle: .alert)
                alert.addAction(.init(title: "OK", style: .default))
                vc.present(alert, animated: true)
            }
            return
        }
        let alert = UIAlertController(
            title: "Voice models",
            message: "Voice calls need on-device models: speech recognition, the voice, and the turn-taking model — a few GB in total. Download them in the background now? You can keep using the app; calls are ready when it finishes.",
            preferredStyle: .alert)
        alert.addAction(.init(title: "Download", style: .default) { _ in
            approved = true
            Task { @MainActor in start(asr: asr, tts: tts) }
        })
        alert.addAction(.init(title: "Not Now", style: .cancel))
        vc.present(alert, animated: true)
    }

    /// Start the background downloads: the speech engines' warm caches plus
    /// the turn tier (`TygerModelStore` — the delivery the loaders read).
    @MainActor
    static func start(asr: String? = nil, tts: String? = nil) {
        guard approved else { return }
        SpeechEngines.prewarm(asr: asr, tts: tts)
        Task { await ensureTurnTier() }
    }

    /// Fetch whatever the on-disk turn tier is missing (the 183-byte
    /// `student.traits.json` included — a tier whose step is present but whose
    /// traits are not counts as not ready). Returns the tier that ended up ready.
    @MainActor
    @discardableResult
    static func ensureTurnTier() async -> String? {
        guard approved else { return nil }
        // Tier choice follows what this OS can *load*, not its version: the
        // 2026-11-01 AOT artifacts (coreai-build 3605.6.3, MPSGraph package
        // 7.1.5) exceed what iOS 27.0.x accepts (≤ 7.0.80) and segfault the
        // Core AI loader, so such a device falls back to the CoreML tier.
        // Rebuilding the AOT with the older Metal toolchain flips this back
        // without a code change (the files then load).
        let tier: String
        if #available(iOS 27.0, *),
           CoreAITurnModel.loadable(in: TygerModelStore.root.appendingPathComponent("coreai")) {
            tier = "coreai"
        } else {
            tier = "coreml"
        }
        let ready = await TygerModelStore.ensure(tier: tier)
        Automation.mark("voice: turn tier \(ready ? "ready" : "download failed") (\(tier))")
        return ready ? tier : nil
    }
}
