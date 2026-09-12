import AppKit

/// Owns the Live Activity Bar's window host and translates call/transfer state
/// into Bar models and intents (AppKit port of the iOS controller,
/// `ios/Idfon/LiveActivityController.swift`).
///
/// mac has no navigation stack: the detail pane shows one peer at a time, the
/// chat header owns idle actions, so the Bar is **call/transfer-driven** — it
/// renders only while a call or a transfer is in flight. `.open` is handed back
/// to the app so a compact pill can reveal its thread.
///
/// Exactly one call machine can be non-idle at a time: an audio invite carries
/// no `media` line, and `media=video-call` belongs to `VideoCall`.
@MainActor
final class LiveActivityController {
    private let panel = OverlayPanel()
    private let client = DaemonClient()

    /// The peer shown in the detail pane; decides expanded vs compact.
    var selectedPeerId: (() -> String?)?
    /// Compact pill clicked: reveal that peer's thread.
    var onOpenPeer: ((String) -> Void)?
    /// Space the bars occupy, so the window can shift content down.
    var onContentInsetChange: ((CGFloat) -> Void)? {
        didSet { onContentInsetChange?(panel.contentInset) }
    }

    private var phase: LiveActivityBarModel.Phase = .idle
    private var micOn = false
    private var camOn = false
    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var timer: Timer?
    private var peerNames: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Placeholder for §3's ephemeral "Free to talk?" ping: the protocol has no
    /// ephemeral envelope, so this is an ordinary low-priority text.
    private static let pingMessage = "Free to talk?"

    init() {
        panel.onIntent = { [weak self] peerId, intent in self?.handle(intent, peerId: peerId) }
        panel.onContentInsetChange = { [weak self] inset in self?.onContentInsetChange?(inset) }
        // Both machines fan out to every observer, so the chat header can
        // register for the same updates without clobbering this one.
        LiveCall.shared.addStateObserver(self)
        VideoCall.shared.addStateObserver(self)
        TransferCenter.shared.onChange = { [weak self] in self?.render() }
        sync()
        Task { await refreshPeerNames() }
    }

    deinit { timer?.invalidate() }

    /// Anchors the overlay under `window`'s title bar and keeps it there.
    func attach(to window: NSWindow) {
        panel.attach(to: window)
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.render() }
            })
        }
        render()
    }

    // MARK: - Machine resolution

    /// Nested types don't inherit the outer type's isolation, so the machine
    /// resolver is explicitly main-actor bound like its callers.
    @MainActor
    private enum Machine {
        case audio(LiveCall)
        case video(VideoCall)

        static var current: Machine? {
            if case .idle = LiveCall.shared.state {} else { return .audio(LiveCall.shared) }
            if case .idle = VideoCall.shared.state {} else { return .video(VideoCall.shared) }
            return nil
        }

        /// The other party: for a video invite that is still pending, the
        /// inviter (`activePeer` is only set once answered).
        var peer: String? {
            switch self {
            case .audio(let call): return call.activePeer
            case .video(let call): return call.activePeer ?? call.pendingPeer
            }
        }

        var phase: LiveActivityBarModel.Phase {
            switch self {
            case .audio(let call):
                switch call.state {
                case .idle: return .idle
                case .calling: return .calling
                case .incoming: return .incoming
                case .inCall: return .inCall
                }
            case .video(let call):
                switch call.state {
                case .idle: return .idle
                case .calling: return .calling
                case .incoming: return .incoming
                case .watching: return .watching
                case .inCall: return .inCall
                }
            }
        }

        var audioAvailable: Bool {
            switch self {
            case .audio(let call): return call.audioAvailable
            case .video(let call): return call.audioAvailable
            }
        }

        var videoAvailable: Bool {
            switch self {
            case .audio: return false
            case .video(let call): return call.videoAvailable
            }
        }

        var audioEnabled: Bool {
            switch self {
            case .audio(let call): return call.audioEnabled
            case .video(let call): return call.audioEnabled
            }
        }

        var videoEnabled: Bool {
            switch self {
            case .audio: return false
            case .video(let call): return call.videoEnabled
            }
        }

        func setAudioEnabled(_ enabled: Bool) {
            switch self {
            case .audio(let call): call.setAudioEnabled(enabled)
            case .video(let call): call.setAudioEnabled(enabled)
            }
        }

        func setVideoEnabled(_ enabled: Bool) {
            switch self {
            case .audio: break
            case .video(let call): call.setVideoEnabled(enabled)
            }
        }

        func answer() {
            switch self {
            case .audio(let call): call.answer()
            case .video(let call): call.answer()
            }
        }

        func decline() {
            switch self {
            case .audio(let call): call.decline()
            case .video(let call): call.decline()
            }
        }

        func hangUp() {
            switch self {
            case .audio(let call): call.hangUp()
            case .video(let call): call.hangUp()
            }
        }
    }

    // MARK: - State → model

    /// Re-derives the Bar from call state; called on every state change and on
    /// the ≤1 Hz in-call tick (the view holds no timer).
    private func sync() {
        let previous = phase
        let machine = Machine.current
        let next = machine?.phase ?? .idle

        // Entering a phase (re)initialises the toggles from the machine's real
        // send state (a call starts mic-only), so the Bar reads the truth.
        if next != previous, next != .idle {
            micOn = machine?.audioEnabled ?? false
            camOn = machine?.videoEnabled ?? false
        }
        phase = next

        if next == .inCall {
            if startedAt == nil { startedAt = Date(); startTimer() }
        } else {
            startedAt = nil
            elapsed = 0
            stopTimer()
        }

        // A fresh call's peer may not be in the name cache yet.
        if next != previous, next != .idle {
            Task { await refreshPeerNames() }
        }
        render()
    }

    private func render() {
        let visible = selectedPeerId?()
        let machine = Machine.current
        let callPeer = (machine?.peer).flatMap { $0.isEmpty ? nil : $0 }
        let transfers = TransferCenter.shared

        var models: [LiveActivityBarModel] = []
        if let callPeer {
            var model = LiveActivityBarModel(peerId: callPeer, handle: barHandle(for: callPeer))
            model.phase = phase
            model.micOn = micOn
            model.camOn = camOn
            model.audioAvailable = machine?.audioAvailable ?? true
            model.videoAvailable = machine?.videoAvailable ?? true
            model.elapsed = elapsed
            model.rows = transfers.rows(for: callPeer)
            model.density = visible == callPeer ? .expanded : .compact
            models.append(model)
        }
        // §4/§6: a transaction whose peer has no Bar of its own becomes a
        // compact pill, so switching threads never hides in-flight work.
        let modeled = Set(models.map(\.peerId))
        for peerId in transfers.activePeerIds where !modeled.contains(peerId) {
            var model = LiveActivityBarModel(peerId: peerId, handle: barHandle(for: peerId))
            model.density = .compact
            model.rows = transfers.rows(for: peerId)
            models.append(model)
        }
        panel.render(models)
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        render()
    }

    // MARK: - Intents

    private func handle(_ intent: LiveActivityBarIntent, peerId: String) {
        switch intent {
        case .answer: Machine.current?.answer()
        case .decline: Machine.current?.decline()
        case .end: Machine.current?.hangUp()
        case .open: onOpenPeer?(peerId)
        case .toggleMic: toggle(peerId: peerId, mic: true)
        case .toggleCam: toggle(peerId: peerId, mic: false)
        case .ping: Task { try? await client.sendText(to: peerId, Self.pingMessage) }
        // Session Tray actions (§4): Cancel aborts the transfer; pause/Stop is
        // for media streams, which have no producer yet.
        case .cancelRow(let id): TransferCenter.shared.cancel(id: id)
        case .togglePauseRow: break
        }
    }

    /// In-call toggles gate the active machine's outgoing streams (send/no-send
    /// — §3 State 3). The machine reports back, so a toggle for an absent track
    /// cannot desync the Bar.
    private func toggle(peerId: String, mic: Bool) {
        guard let machine = Machine.current, peerId == machine.peer else { return }
        if mic { machine.setAudioEnabled(!machine.audioEnabled) } else { machine.setVideoEnabled(!machine.videoEnabled) }
        micOn = machine.audioEnabled
        camOn = machine.videoEnabled
        render()
    }

    // MARK: - Peer names

    /// Refreshes the peer-id → display-name map the Bar renders with.
    private func refreshPeerNames() async {
        guard let peers = try? await client.peers() else { return }
        peerNames = peers.reduce(into: [:]) { names, peer in
            if let name = peer.name, !name.isEmpty { names[peer.id] = name }
        }
        render()
    }

    /// Bar title for a peer: the display name when known, else a shortened id —
    /// never the full public key.
    private func barHandle(for peerId: String) -> String {
        if let name = peerNames[peerId] { return "@\(name)" }
        return peerId.count > 13 ? "@\(peerId.prefix(8))…" : "@\(peerId)"
    }
}

extension LiveActivityController: CallStateObserver {
    func callStateDidChange() { sync() }
}
