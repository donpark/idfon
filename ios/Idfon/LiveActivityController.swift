import UIKit

/// Owns the Live Activity Bar's window host for one scene and translates the
/// active call machine's state (`LiveCall` or `VideoCall`) into Bar models and
/// intents. Exactly one machine can be non-idle at a time.
///
/// Bar mode is the default in-app call surface until CallKit lands
/// (docs/ui-design-notes.md §6, §7.1): incoming calls ring inline in the Bar
/// — there is no fullscreen ringing screen. `CallViewController` remains the
/// expanded video surface, presented from the chat's inline video bar.
@MainActor
final class LiveActivityController: NSObject {
    /// The overlay window. Strong here (the scene holds this controller); an
    /// unreferenced `UIWindow` deallocates silently.
    let overlay: OverlayWindow

    /// The tab root. The Bar renders through whichever tab is selected; every
    /// tab's nav gets the clearance/inset wiring. Weak: the window owns it.
    weak var tabBarController: UITabBarController? {
        didSet {
            tabBarController?.delegate = self
            // One overlay callback fans out to every tab's nav.
            overlay.onContentInsetChange = { [weak self] inset in
                self?.navigationControllers.forEach { $0.applyContentInset(inset) }
            }
            navigationControllers.forEach {
                $0.onVisibleControllerChanged = { [weak self] in self?.render() }
                $0.onLayout = { [weak self] in self?.syncClearance() }
            }
            navigationControllers.forEach { $0.applyContentInset(overlay.contentInset) }
            syncClearance()
            render()
        }
    }

    /// Every tab is an `AppNavigationController`; clearance and inset apply to
    /// all of them, density and `topClearance` follow the selected one.
    private var navigationControllers: [AppNavigationController] {
        (tabBarController?.viewControllers ?? []).compactMap { $0 as? AppNavigationController }
    }

    /// The selected tab's nav, which owns `topClearance` and density.
    private var visibleNavigationController: AppNavigationController? {
        tabBarController?.selectedViewController as? AppNavigationController
    }

    private func syncClearance() {
        overlay.topClearance = visibleNavigationController?.topClearance ?? 0
    }

    private let client = DaemonClient()

    /// peer-id → display name, so the Bar shows a callee name instead of the
    /// raw iroh public key (#3). Refreshed on call start and on resolution.
    private var peerNames: [String: String] = [:]

    private var phase: LiveActivityBarModel.Phase = .idle
    /// The in-call Bar's toggle state. Mirrored from the active machine on
    /// phase entry and after each toggle, so the Bar always shows what the
    /// call is really sending (and hides toggles for absent tracks).
    private var micOn = false
    private var camOn = false

    /// Body of the idle Bar's `.ping`: placeholder for the spec's ephemeral
    /// "Free to talk?" notification (the protocol has no ephemeral envelope).
    private static let pingMessage = "Free to talk?"

    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var timer: Timer?

    /// The call machine owning the Bar. Exactly one can be non-idle: an
    /// audio invite carries no `media` line and a `media=video-call` invite
    /// belongs to `VideoCall`; each machine ignores the other's envelopes.
    @MainActor
    private enum ActiveMachine {
        case audio(LiveCall)
        case video(VideoCall)

        /// Non-nil while a call is in flight on either machine.
        static var current: ActiveMachine? {
            if LiveCall.shared.state != .idle { return .audio(LiveCall.shared) }
            if VideoCall.shared.state != .idle { return .video(VideoCall.shared) }
            return nil
        }

        var peer: String? {
            switch self {
            case .audio(let call): return call.activePeer
            case .video(let call): return call.activePeer
            }
        }

        /// What the session carries — immutable for the call's life, so the
        /// Bar hides a toggle for a track this call does not publish (§3).
        var audioAvailable: Bool {
            switch self {
            case .audio(let call): return call.audioAvailable
            case .video(let call): return call.audioAvailable
            }
        }

        var videoAvailable: Bool {
            switch self {
            case .audio(let call): return call.videoAvailable
            case .video(let call): return call.videoAvailable
            }
        }

        /// Whether each stream is currently being sent (mute/unmute, camera
        /// on/off) — send/no-send gating, never track attach/detach.
        var audioEnabled: Bool {
            switch self {
            case .audio(let call): return call.audioEnabled
            case .video(let call): return call.audioEnabled
            }
        }

        var videoEnabled: Bool {
            switch self {
            case .audio(let call): return call.videoEnabled
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
            case .audio(let call): call.setVideoEnabled(enabled)
            case .video(let call): call.setVideoEnabled(enabled)
            }
        }

        var phase: LiveActivityBarModel.Phase {
            switch self {
            case .audio(let call): return Self.phase(for: call.state)
            case .video(let call): return Self.phase(for: call.state)
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

        private static func phase(for state: LiveCall.State) -> LiveActivityBarModel.Phase {
            switch state {
            case .idle: return .idle
            case .calling: return .calling
            case .incoming: return .incoming
            case .inCall: return .inCall
            }
        }

        private static func phase(for state: VideoCall.State) -> LiveActivityBarModel.Phase {
            switch state {
            case .idle: return .idle
            case .calling: return .calling
            case .incoming: return .incoming
            case .inCall: return .inCall
            }
        }
    }

    init(windowScene: UIWindowScene) {
        overlay = OverlayWindow(windowScene: windowScene)
        super.init()
        overlay.onIntent = { [weak self] peerId, intent in
            self?.handle(intent, peerId: peerId)
        }
        // Session Tray rows refresh whenever a transfer progresses (§4).
        TransferCenter.shared.onChange = { [weak self] in self?.render() }
        // Take ownership of both machines' state hooks (the scene delegate no
        // longer sets them); the Bar renders whichever one is non-idle.
        LiveCall.shared.onState = { [weak self] in self?.sync() }
        VideoCall.shared.onState = { [weak self] in self?.sync() }
        // Render the state as it is now: a call can already be in flight before
        // this controller exists (launch-argument dial, scene reconnection).
        sync()
        // Prime the per-connection incoming-call modes (§6); refreshed after a
        // mode change too. Incoming invites before this lands fall back to Bar.
        Task { await IncomingCallRouter.shared.refreshModes() }
        Task { await refreshPeerNames() }
    }

    deinit { timer?.invalidate() }

    /// Re-derives the Bar from call state; called on every state change and
    /// on the ≤1 Hz in-call tick (the view itself holds no timer).
    private func sync() {
        let previous = phase
        let machine = ActiveMachine.current
        let next = machine?.phase ?? .idle

        // Entering a phase (re)initialises the toggles from the machine's
        // real send state. A call only publishes its staged tracks (dial) or
        // both (answer), and an unanswered incoming call is not sending yet,
        // so the Bar reads the truth instead of assuming mic-on/cam-on.
        if next != previous, next != .idle {
            micOn = machine?.audioEnabled ?? false
            camOn = machine?.videoEnabled ?? false
        }
        phase = next

        if next == .inCall {
            if startedAt == nil {
                startedAt = Date()
                startTimer()
            }
        } else {
            startedAt = nil
            elapsed = 0
            stopTimer()
        }

        // Answering an incoming call takes you into the callee's thread, so the
        // inline call surface is already on screen without a tap (#1).
        if previous == .incoming, next == .inCall, let peer = machine?.peer, !peer.isEmpty {
            openPeerThreadIfNeeded(peer)
        }
        // A fresh incoming invite's peer may not be in the name cache yet.
        if next != previous, next != .idle {
            Task { await refreshPeerNames() }
        }
        render()
    }

    /// Produces up to three models: the visible thread's own chrome first,
    /// then the call's, then pills for peers with only tray activity
    /// (docs/ui-design-notes.md §3, §4, §6).
    ///
    /// - Idle: the visible thread's expanded State 1/2 chrome plus its Session
    ///   Tray rows; nothing on any other screen unless it has a transfer.
    /// - In a call with C: C expanded when its thread is visible; when another
    ///   thread P is visible, P's expanded idle chrome plus C's compact pill;
    ///   with no thread visible, C's compact pill only.
    /// - A transfer to/from a peer with no Bar becomes its own compact pill, so
    ///   leaving the thread never hides in-flight work.
    private func render() {
        let visiblePeer = (visibleNavigationController?.visibleViewController as? ChatViewController)?.peer.id
        let machine = ActiveMachine.current
        let callPeer = (machine?.peer ?? nil).flatMap { $0.isEmpty ? nil : $0 }

        let transfers = TransferCenter.shared
        var models: [LiveActivityBarModel] = []
        if phase == .idle {
            if let peerId = visiblePeer {
                var model = idleModel(for: peerId)
                model.rows = transfers.rows(for: peerId)
                models.append(model)
            }
        } else if let callPeer {
            if let peerId = visiblePeer, peerId != callPeer {
                var model = idleModel(for: peerId)
                model.rows = transfers.rows(for: peerId)
                models.append(model)
            }
            var model = LiveActivityBarModel(peerId: callPeer, handle: barHandle(for: callPeer))
            model.phase = phase
            model.micOn = micOn
            model.camOn = camOn
            model.audioAvailable = machine?.audioAvailable ?? true
            model.videoAvailable = machine?.videoAvailable ?? true
            model.elapsed = elapsed
            model.rows = transfers.rows(for: callPeer)
            // Expanded only while the visible thread is the call peer's —
            // that thread owns the call; every other screen shows the pill.
            model.density = visiblePeer == callPeer ? .expanded : .compact
            models.append(model)
        }
        // §4/§6: a transaction whose peer has no Bar renders as a compact pill,
        // so leaving the thread never hides in-flight work.
        let modeled = Set(models.map(\.peerId))
        for peerId in transfers.activePeerIds where !modeled.contains(peerId) {
            var model = LiveActivityBarModel(peerId: peerId, handle: barHandle(for: peerId))
            model.density = .compact
            model.rows = transfers.rows(for: peerId)
            models.append(model)
        }
        overlay.render(models)
    }

    /// State 1 chrome for `peerId`: idle phase, Ping verb, no stream toggles.
    private func idleModel(for peerId: String) -> LiveActivityBarModel {
        var model = LiveActivityBarModel(peerId: peerId, handle: barHandle(for: peerId))
        model.phase = .idle
        model.density = .expanded
        return model
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
        case .answer: ActiveMachine.current?.answer()
        case .decline: ActiveMachine.current?.decline()
        case .end: ActiveMachine.current?.hangUp()
        case .open: openPeerThread(peerId)
        case .toggleMic: toggleSendState(peerId: peerId, mic: true)
        case .toggleCam: toggleSendState(peerId: peerId, mic: false)
        // Placeholder for §3's ephemeral "Free to talk?" ping: the protocol
        // has no ephemeral envelope, so this is an ordinary low-priority text
        // (delivered to the peer's thread, it does not ring like a call).
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
    private func toggleSendState(peerId: String, mic: Bool) {
        guard let machine = ActiveMachine.current, peerId == (machine.peer ?? nil) else { return }
        if mic { machine.setAudioEnabled(!machine.audioEnabled) } else { machine.setVideoEnabled(!machine.videoEnabled) }
        micOn = machine.audioEnabled
        camOn = machine.videoEnabled
        render()
    }

    /// Best-effort jump to the peer's thread: an already-pushed thread is
    /// popped to; otherwise resolve the peer and push a new one.
    private func openPeerThread(_ peerId: String) {
        guard let navigationController = visibleNavigationController else { return }
        if let existing = navigationController.viewControllers
            .compactMap({ $0 as? ChatViewController })
            .first(where: { $0.peer.id == peerId }) {
            navigationController.popToViewController(existing, animated: true)
            return
        }
        Task {
            let peer = await resolvePeer(peerId)
            navigationController.pushViewController(ChatViewController(peer: peer), animated: true)
        }
    }

    // MARK: - Automation (scripts/ios-device-test.sh)

    /// Opens `peerRef`'s thread and hands back the controller, so a headless run
    /// can drive the same path a tap would. Returns nil without a scene.
    func automateOpenThread(peerRef: String) async -> ChatViewController? {
        guard let navigationController = visibleNavigationController else { return nil }
        let chat = ChatViewController(peer: await resolvePeer(peerRef))
        navigationController.pushViewController(chat, animated: false)
        return chat
    }

    /// Opens the peer's thread unless it is already the visible one.
    private func openPeerThreadIfNeeded(_ peerId: String) {
        let visible = (visibleNavigationController?.visibleViewController as? ChatViewController)?.peer.id
        guard visible != peerId else { return }
        openPeerThread(peerId)
    }

    /// Refreshes the peer-id → display-name map the Bar renders with.
    private func refreshPeerNames() async {
        guard let peers = try? await client.peers() else { return }
        peerNames = peers.reduce(into: [:]) { names, peer in
            if let name = peer.name, !name.isEmpty { names[peer.id] = name }
        }
        render()
    }

    /// Bar title for a peer: the display name when known, else a shortened id —
    /// never the full public key (#3).
    private func barHandle(for peerId: String) -> String {
        if let name = peerNames[peerId] { return "@\(name)" }
        return peerId.count > 13 ? "@\(peerId.prefix(8))…" : "@\(peerId)"
    }

    private func resolvePeer(_ peerId: String) async -> Peer {
        if let match = (try? await client.peers())?.first(where: { $0.id == peerId || $0.name == peerId }) {
            if let name = match.name, !name.isEmpty { peerNames[match.id] = name }
            return match
        }
        return Peer(id: peerId, name: nil, endpointId: nil, aliases: nil, callMode: nil)
    }
}

/// Tab changes re-anchor the Bar to the newly selected tab and re-evaluate
/// density, so a call whose thread is behind another tab shows as a pill.
extension LiveActivityController: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        syncClearance()
        render()
    }
}
