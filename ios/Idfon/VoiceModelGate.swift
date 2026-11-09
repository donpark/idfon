import TygerVoice
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

    @MainActor
    private final class ProgressNotice {
        private weak var presenter: UIViewController?
        private var alert: UIAlertController?
        private var finished = false

        init(presenter: UIViewController, showInitially: Bool) {
            self.presenter = presenter
            if showInitially { show("Checking the model manifest…") }
        }

        var report: @MainActor @Sendable (String, Int64, Int64) -> Void {
            { [weak self] tier, completed, total in self?.update(tier, completed: completed, total: total) }
        }

        func finish(tier: String?) {
            finished = true
            guard let alert else { return }
            switch tier {
            case "prefix":
                alert.title = "Prefix turn model ready"
                alert.message = "The selected 100 MB turn model is verified and ready."
            case "coreai":
                alert.title = "CoreAI turn model ready"
                alert.message = "The CoreAI model is verified and available as fallback."
            case "classic":
                alert.title = "Classic turn-taking ready"
                alert.message = "No Tyger model is used on this iOS version."
            default:
                alert.title = "Turn model update incomplete"
                alert.message = "The current model was kept. Check storage or network, then try again."
            }
        }

        private func update(_ tier: String, completed: Int64, total: Int64) {
            guard !finished, completed < total || alert != nil else { return }
            let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            show("\(tier) model: \(done) of \(size)")
        }

        private func show(_ message: String) {
            if alert == nil {
                let alert = UIAlertController(title: "Turn model update", message: message, preferredStyle: .alert)
                alert.addAction(.init(title: "Hide", style: .cancel))
                self.alert = alert
                presenter?.present(alert, animated: true)
            } else {
                alert?.message = message
            }
        }
    }

    /// Is the voice-agent's ASR on disk? The selected backend owns its cache.
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

    /// Whether the selected turn policy is ready; pre-27 classic needs no model.
    static func turnTierReady() -> Bool {
        guard #available(iOS 27.0, *) else { return true }
        let dir = TygerModelStore.root
        let coreai = dir.appendingPathComponent("coreai")
        if CoreAITurnModel.loadable(in: coreai) {
            let student = CoreAITurnModel.studentStep(in: coreai)
            if !student || coreAITraitsAreCurrent(in: coreai, shared: dir) { return true }
        }
        guard TurnPrefix.isEnabled(environment: ProcessInfo.processInfo.environment),
              let prefix = TurnPrefix.artifact(in: dir) else { return false }
        return hasCoreMLPackage(at: prefix)
            && hasCoreMLPackage(at: dir.appendingPathComponent("StudentStep.mlpackage"))
    }

    static func hasCoreMLPackage(at package: URL, requiresDebugMapping: Bool = false) -> Bool {
        var files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                     "Data/com.apple.CoreML/weights/weight.bin"]
        if requiresDebugMapping { files.append("executorch_debug_handle_mapping.json") }
        return files.allSatisfy { path in
            let file = package.appendingPathComponent(path)
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
            return size > 0
        }
    }

    static func coreAITraitsAreCurrent(in coreai: URL, shared: URL) -> Bool {
        guard let installed = try? Data(contentsOf: coreai.appendingPathComponent("student.traits.json")),
              let current = try? Data(contentsOf: shared.appendingPathComponent("student.traits.json")) else {
            return false
        }
        return installed == current
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
            let ready = asrReady() && turnTierReady()
            let notice = ProgressNotice(presenter: vc, showInitially: !ready)
            if !ready { SpeechEngines.prewarm(asr: asr, tts: tts) }
            Task {
                let tier = await ensureTurnTier(onProgress: notice.report)
                notice.finish(tier: tier)
            }
            return
        }
        let message: String
        if #available(iOS 27.0, *) {
            message = "Voice-agent calls use on-device speech, voice, and the iOS 27 turn model. Download these models in the background?"
        } else {
            message = "Voice-agent calls use on-device speech and voice. Classic turn-taking stays active on this iOS version. Download the speech models in the background?"
        }
        let alert = UIAlertController(title: "Voice models", message: message, preferredStyle: .alert)
        alert.addAction(.init(title: "Download", style: .default) { _ in
            approved = true
            Task { @MainActor in
                let notice = ProgressNotice(presenter: vc, showInitially: true)
                start(asr: asr, tts: tts, notice: notice)
            }
        })
        alert.addAction(.init(title: "Not Now", style: .cancel))
        vc.present(alert, animated: true)
    }

    /// Start speech warmups and reconcile the selected turn tier after approval.
    @MainActor
    private static func start(asr: String? = nil, tts: String? = nil, notice: ProgressNotice) {
        guard approved else { return }
        SpeechEngines.prewarm(asr: asr, tts: tts)
        Task {
            let tier = await ensureTurnTier(onProgress: notice.report)
            notice.finish(tier: tier)
        }
    }

    /// Fetch or update the on-disk tier and its per-model traits. Returns the
    /// tier that ended up ready.
    @MainActor
    @discardableResult
    static func ensureTurnTier(
        onProgress: (@MainActor @Sendable (String, Int64, Int64) -> Void)? = nil
    ) async -> String? {
        guard approved else { return nil }
        guard #available(iOS 27.0, *) else {
            Automation.mark("voice: turn tier classic (pre-iOS 27; no Tyger download)")
            return "classic"
        }

        let root = TygerModelStore.root
        let coreai = root.appendingPathComponent("coreai")
        let downloaded = await TygerModelStore.ensure(tier: "coreai", onProgress: onProgress)
        let coreaiReady = downloaded && CoreAITurnModel.loadable(in: coreai)
        Automation.mark("voice: turn tier \(coreaiReady ? "ready" : "unloadable; classic fallback") (coreai)")

        var prefixReady = false
        if TurnPrefix.isEnabled(environment: ProcessInfo.processInfo.environment) {
            _ = await TygerModelStore.ensure(tier: "prefix", onProgress: onProgress)
            if let prefix = TurnPrefix.artifact(in: root) {
                prefixReady = hasCoreMLPackage(at: prefix)
                    && hasCoreMLPackage(at: root.appendingPathComponent("StudentStep.mlpackage"))
            }
            Automation.mark("voice: turn prefix \(prefixReady ? "ready" : "unavailable")")
        }
        return prefixReady ? "prefix" : (coreaiReady ? "coreai" : "classic")
    }
}
