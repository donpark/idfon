import AppKit
import CIdfon

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    /// Retains deep-linked edge resource windows.
    private var edgeWindows: [NSWindow] = []

    /// The @main-synthesized NSApplicationMain did not wire this delegate in
    /// this SPM executable (no callbacks fired); run NSApplication by hand.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DaemonRuntime.configure()
        // Public edge endpoint + requester credential (P4 parity):
        // `-edgeurl <url> <ticket>` or `-edgeurl <url> -edgeticket <ticket>`.
        let launchArgs = ProcessInfo.processInfo.arguments
        if let i = launchArgs.firstIndex(of: "-edgeurl"), launchArgs.count > i + 1 {
            var ticket: String?
            if launchArgs.count > i + 2, !launchArgs[i + 2].hasPrefix("-") {
                ticket = launchArgs[i + 2]
            } else if let j = launchArgs.firstIndex(of: "-edgeticket"), launchArgs.count > j + 1 {
                ticket = launchArgs[j + 1]
            }
            if let ticket { EdgeClient.configure(url: launchArgs[i + 1], ticket: ticket) }
        }
        ChatStore.shared.start()
        Task { await DaemonClient().startSharedProvider() }
        // Warm the selected reply voice early, so the first call's greeting is
        // not blocked by a cold Kokoro download/compile.
        Task { @MainActor in SpeechEngines.prewarm() }
        LiveCall.shared.recoverStaleCall()
        VideoCall.shared.recoverStaleCall()
        buildMenu()
        buildWindow()
        // GUI parity: an incoming invite always surfaces — open the caller's
        // chat (its header shows Answer/Decline) and bring the app forward.
        LiveCall.shared.onIncoming = { [weak self] peerID in
            self?.surfaceIncoming(peerID: peerID, label: "Incoming call")
        }
        VideoCall.shared.onIncoming = { [weak self] peerID, watchOnly in
            self?.surfaceIncoming(peerID: peerID, label: watchOnly ? "Incoming video" : "Incoming video call")
        }
        // Contact invites from a trusted directory enroll silently; everyone
        // else prompts. The message is already sender-authenticated.
        ChatStore.shared.onInvite = { invite, sender in
            let alert = NSAlert()
            alert.messageText = "Add \(invite.name)?"
            alert.informativeText = (invite.model.isEmpty ? "" : "Model: \(invite.model)\n")
                + "This invite came from a sender you have not marked as trusted."
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Add and Always Trust")
            alert.addButton(withTitle: "Ignore")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                ChatStore.shared.acceptInvite(invite)
            case .alertSecondButtonReturn:
                AutoEnroll.trust(sender)
                ChatStore.shared.acceptInvite(invite)
            default:
                break
            }
        }
        Task { await app.refresh() }
        runAutomationIfRequested()
        runCallAutomationIfRequested()
    }

    /// Pick up any edge fetch that completed while the app was inactive.
    func applicationDidBecomeActive(_ notification: Notification) {
        _ = EdgeClient.shared.drainInbox()
    }

    private func surfaceIncoming(peerID: String, label: String) {
        Task { @MainActor in
            if app.selectedPeer?.id != peerID,
               let match = app.peers.first(where: { $0.id == peerID }) {
                app.select(match)
            }
            ChatStore.shared.onBanner?(label)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// `idfon://` deep links (grammar: `IdfonURL`):
    ///   idfon://<peer-ref>[/path]  — select that peer's chat
    ///   idfon://dial/<peer-ref>    — dial a peer
    ///   idfon://videodial/<ref>    — start a video call
    ///   idfon://answer             — arm auto-answer
    /// The resource path is parsed but not yet routed to a screen.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = IdfonURL(url) else { continue }
            idfonLog("idfon openURL: \(url)")
            switch link {
            case .resource(let ref, let path):
                if EdgeClient.shared.isConfigured, !path.isEmpty {
                    openEdgeResource(ref: ref, path: path)
                } else {
                    openPeerThread(ref: ref)
                }
            case .dial(let ref):
                LiveCall.shared.dial(ref)
            case .videoDial(let ref):
                VideoCall.shared.dial(ref)
            case .answer:
                waitForIncomingCall(video: false)
            }
        }
    }

    /// Selects the peer's chat, or a synthetic peer when the ref names nobody
    /// (same fallback the automation paths use).
    private func openPeerThread(ref: String) {
        let match = app.peers.first(where: { $0.matches(ref: ref) })
            ?? Peer(id: ref, name: nil, endpointId: nil, aliases: nil)
        app.select(match)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a peer resource (`idfon://<ref>/<path>`) in a sandboxed web view
    /// at the gateway/edge URL (`docs/idfon-edge.md`, P4 parity).
    private func openEdgeResource(ref: String, path: [String]) {
        let resourcePath = "/" + path.joined(separator: "/")
        Task { @MainActor in
            // The deep link targets the public edge (parity with the iOS
            // EdgeWebView); the artifact screen is what uses loopback-first.
            guard let url = EdgeClient.shared.url(account: ref, path: resourcePath) else {
                openPeerThread(ref: ref)
                return
            }
            let source = GatewayArtifactSource(
                route: .edge, url: url,
                cookie: EdgeClient.shared.cookie(for: url), host: url.host ?? "")
            let web = SandboxedArtifactWebView(
                source: source, frame: NSRect(x: 0, y: 0, width: 720, height: 560))
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
            web.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(web)
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: controller.view.topAnchor),
                web.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            ])
            controller.preferredContentSize = NSSize(width: 720, height: 560)
            let window = NSWindow(contentViewController: controller)
            window.title = ref
            window.setContentSize(NSSize(width: 720, height: 560))
            window.makeKeyAndOrderFront(nil)
            edgeWindows.append(window)
        }
    }

    private func buildWindow() {
        // Plain manual split: fixed sidebar, flexible detail. (NSSplitView-
        // Controller's sidebar item sizing fought with our root views.)
        let sidebar = SidebarViewController(app: app)
        let detail = DetailContainerViewController(app: app)
        self.detail = detail
        let split = NSViewController()
        split.view = NSView()
        split.view.addSubview(sidebar.view)
        split.addChild(sidebar)
        split.view.addSubview(detail.view)
        split.addChild(detail)
        for child in [sidebar.view, detail.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        // Spacer that absorbs the Live Activity Bar's height, so content shifts
        // down under the overlay instead of hiding behind it. Height 0 = no bar.
        let topInset = NSView()
        topInset.translatesAutoresizingMaskIntoConstraints = false
        split.view.addSubview(topInset)
        let topInsetHeight = topInset.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topInset.topAnchor.constraint(equalTo: split.view.topAnchor),
            topInset.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            topInset.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
            topInsetHeight,
            sidebar.view.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: topInset.bottomAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            sidebar.view.widthAnchor.constraint(equalToConstant: 280),
            detail.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: 1),
            detail.view.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
            detail.view.topAnchor.constraint(equalTo: topInset.bottomAnchor),
            detail.view.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        self.topInsetHeight = topInsetHeight

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Idfon"
        window.contentViewController = split
        // The window auto-sizes to the content's fitting size; pin it to a
        // sane minimum so the panes don't collapse it.
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.center()
        self.window = window // retain: a window not owned by the delegate can be released
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The Live Activity Bar overlay: anchored under the title bar, reporting
        // the space it needs so the split shifts down.
        liveActivity.selectedPeerId = { [weak app] in app?.selectedPeer?.id }
        liveActivity.onOpenPeer = { [weak self] peerId in
            guard let self, let match = self.app.peers.first(where: { $0.id == peerId || $0.name == peerId })
            else { return }
            self.app.select(match)
            self.window?.makeKeyAndOrderFront(nil)
        }
        liveActivity.onContentInsetChange = { [weak self] inset in
            self?.topInsetHeight?.constant = inset
        }
        liveActivity.attach(to: window)
    }

    private var window: NSWindow?
    private var topInsetHeight: NSLayoutConstraint?
    private var detail: DetailContainerViewController?
    private let liveActivity = LiveActivityController()

    /// Launch arguments exercise the real Swift media state machines without
    /// UI taps. They are intended for paired-device E2E runs.
    private func runCallAutomationIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "-dial"), args.count > index + 1 {
            let peer = args[index + 1]
            Task { @MainActor in
                await app.refresh()
                if let match = app.peers.first(where: { $0.id == peer || $0.name == peer }) {
                    app.select(match)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                LiveCall.shared.dial(peer)
                idfonLog("idfon audio dial started: \(peer)")
            }
        }
        if let index = args.firstIndex(of: "-videodial"), args.count > index + 1 {
            let peer = args[index + 1]
            Task { @MainActor in
                VideoCall.shared.resetForAutomation()
                await app.refresh()
                let match = app.peers.first(where: { $0.id == peer || $0.name == peer })
                if let match {
                    app.select(match)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    VideoCall.shared.dial(match.id)
                } else {
                    VideoCall.shared.dial(peer)
                }
                idfonLog("idfon video dial started: \(peer)")
            }
        }
        if args.contains("-answer") { waitForIncomingCall(video: false) }
        if args.contains("-videoanswer") { waitForIncomingCall(video: true) }
        if args.contains("-bargein") {
            // Off main: synthesizePCM blocks its caller while the synthesizer
            // runs on main, so the caller must not be main.
            DispatchQueue.global(qos: .userInitiated).async {
                OnDeviceVoice.shared.runBargeInExercise()
            }
        }
        if args.contains("-voicelistening") {
            DispatchQueue.global(qos: .userInitiated).async {
                OnDeviceVoice.shared.runListeningTest()
            }
        }
        if let i = args.firstIndex(of: "-voiceagenttext"), args.count > i + 2 {
            let ref = args[i + 1]
            let text = args[i + 2]
            Task { @MainActor in VoiceAgentSession.shared.runText(peerRef: ref, text: text) }
        }
        if let i = args.firstIndex(of: "-voiceagent"), args.count > i + 1 {
            let ref = args[i + 1]
            let turns = args.count > i + 2 ? (Int(args[i + 2]) ?? 1) : 1
            Task { @MainActor in VoiceAgentSession.shared.run(peerRef: ref, turns: turns) }
        }
        if args.contains("-voices") {
            SpeechVoice.dump()
        }
    }

    private func waitForIncomingCall(video: Bool) {
        Task { @MainActor in
            for _ in 0..<600 {
                if video, VideoCall.shared.state == .incoming {
                    VideoCall.shared.answer()
                    idfonLog("idfon video answer started")
                    return
                }
                if !video, case .incoming = LiveCall.shared.state {
                    LiveCall.shared.answer()
                    idfonLog("idfon audio answer started")
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            idfonLog("idfon \(video ? "video" : "audio") answer timed out")
        }
    }

    /// `-sendfile <peer> <path>` drives the real attachment path with no clicks
    /// (see `Automation.swift` / `scripts/mac-e2e.sh`).
    private func runAutomationIfRequested() {
        // `-pair-ticket <peer-ref> <json|file>`: persist a capability ticket
        // minted by the peer's holder so outbound sends pass its ingress gate
        // (mac port of the iOS AppDelegate `-pair-ticket` flow).
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "-trust-enroll"), args.count > index + 1 {
            AutoEnroll.trust(args[index + 1])
            Automation.mark("trust-enroll \(args[index + 1])")
        }
        if let index = args.firstIndex(of: "-pair-ticket"), args.count > index + 2 {
            let peer = args[index + 1]
            let jsonOrPath = args[index + 2]
            let json: String
            if jsonOrPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                json = jsonOrPath
            } else if let contents = try? String(contentsOfFile: jsonOrPath, encoding: .utf8) {
                json = contents
            } else {
                Automation.mark("pair-ticket FAIL not JSON or a readable file")
                return
            }
            if CapabilityTickets.store(json, for: peer) {
                Automation.mark("pair-ticket stored for peer \(peer)")
            } else {
                Automation.mark("pair-ticket FAIL not a JSON object")
            }
        }
        guard let pending = Automation.pendingSendFile else { return }
        Task { @MainActor in
            // Let the window and daemon settle before touching media/threads.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            Automation.mark("sendfile start peer=\(pending.peer) file=\(pending.path)")
            let url = URL(fileURLWithPath: pending.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Automation.mark("sendfile FAIL missing \(pending.path)")
                return
            }
            // Fall back to a synthetic peer, so the plumbing (thread -> tray ->
            // transfer) is still exercised when the ref names nobody.
            let match = app.peers.first(where: { $0.id == pending.peer || $0.name == pending.peer })
                ?? Peer(id: pending.peer, name: nil, endpointId: nil, aliases: nil)
            app.select(match)
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let chat = detail?.currentChat else {
                Automation.mark("sendfile FAIL no chat")
                return
            }
            chat.automateSendFile(at: url)
        }
    }

    /// Minimal menu bar with Quit and an Emergency Stop (halts all media).
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.title = "Idfon"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Idfon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edge (public ingress) settings: URL + requester ticket.
        let settingsMenu = NSMenu(title: "Settings")
        settingsMenu.addItem(NSMenuItem(
            title: "Edge…", action: #selector(showEdgeSettings), keyEquivalent: ""))
        settingsMenu.addItem(NSMenuItem(
            title: "Relay…", action: #selector(showRelaySettings), keyEquivalent: ""))
        let settingsItem = NSMenuItem()
        settingsItem.title = "Settings"
        settingsItem.submenu = settingsMenu
        main.addItem(settingsItem)

        let mediaMenu = NSMenu(title: "Media")
        let stop = NSMenuItem(title: "Emergency Stop", action: #selector(emergencyStop), keyEquivalent: "")
        stop.keyEquivalentModifierMask = [.command, .shift]
        mediaMenu.addItem(stop)
        let mediaItem = NSMenuItem()
        mediaItem.title = "Media"
        mediaItem.submenu = mediaMenu
        main.addItem(mediaItem)

        let sessionsMenu = NSMenu(title: "Sessions")
        let persist = NSMenuItem(
            title: "Persist Session Logs", action: #selector(togglePersistLogs), keyEquivalent: "")
        persist.state = SessionStore.shared.persistLogs ? .on : .off
        sessionsMenu.addItem(persist)
        let sessionsItem = NSMenuItem()
        sessionsItem.title = "Sessions"
        sessionsItem.submenu = sessionsMenu
        main.addItem(sessionsItem)

        NSApp.mainMenu = main
    }

    /// Edge URL + requester ticket, persisted through `EdgeClient` (P4).
    @objc private func showEdgeSettings() {
        let alert = NSAlert()
        alert.messageText = "Edge"
        alert.informativeText = "Public edge URL and requester ticket, persisted on this Mac."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        let urlField = NSTextField(string: EdgeClient.shared.baseURL?.absoluteString ?? "")
        urlField.placeholderString = "https://idfon.net"
        let ticketField = NSTextField(string: EdgeClient.shared.ticket ?? "")
        ticketField.placeholderString = "requester ticket"
        urlField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        ticketField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "URL"), urlField,
            NSTextField(labelWithString: "Ticket"), ticketField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        alert.accessoryView = stack
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ticket = ticketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !ticket.isEmpty { EdgeClient.configure(url: url, ticket: ticket) }
        case .alertThirdButtonReturn:
            EdgeClient.clear()
        default:
            break
        }
    }

    /// Enterprise relay URL(s) + optional token, persisted and applied when the
    /// daemon subprocess starts (`RelaySettings`).
    @objc private func showRelaySettings() {
        let alert = NSAlert()
        alert.messageText = "Relay"
        alert.informativeText = "Enterprise iroh relay URL(s), comma-separated. Token is optional — prefer a relay that authorizes endpoint ids."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        let urlsField = NSTextField(string: RelaySettings.urls ?? "")
        urlsField.placeholderString = "https://relay.idfon.net:8443"
        let tokenField = NSTextField(string: RelaySettings.token ?? "")
        tokenField.placeholderString = "relay token (optional)"
        urlsField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        tokenField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "URL(s)"), urlsField,
            NSTextField(labelWithString: "Token"), tokenField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        alert.accessoryView = stack
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            RelaySettings.configure(
                urls: urlsField.stringValue,
                token: tokenField.stringValue,
                relayOnly: RelaySettings.isRelayOnly)
        case .alertThirdButtonReturn:
            RelaySettings.clear()
        default:
            break
        }
    }

    /// Session logs are ephemeral cache by default; this opt-in moves them to
    /// Application Support so a session survives cache pressure.
    @objc private func togglePersistLogs(_ sender: NSMenuItem) {
        let next = !SessionStore.shared.persistLogs
        SessionStore.shared.persistLogs = next
        sender.state = next ? .on : .off
        ChatStore.shared.onBanner?(next ? "Persisting session logs" : "Session logs are ephemeral")
    }

    @objc private func emergencyStop() {
        Task.detached(priority: .userInitiated) { media_emergency_stop() }
        ChatStore.shared.onBanner?("Emergency stop")
    }
}

/// App-level state: daemon status, identities, peers, selection.
@MainActor
final class AppModel: NSObject {
    var identities: [IdentityInfo] = []
    var peers: [Peer] = []
    var rooms: [Room] = []
    var ready = false
    var identityName = ""
    var endpointTicket = ""
    var statusText = "Connecting"
    var addError: String?

    /// Fired on the main queue whenever any of the above changed.
    var onUpdate: (() -> Void)?
    /// Fired when the selected peer changed (detail swap).
    var onSelection: ((Peer?) -> Void)?
    var onRoomSelection: ((Room?) -> Void)?

    private(set) var selectedPeer: Peer?
    private(set) var selectedRoom: Room?

    let client = DaemonClient()

    func select(_ peer: Peer?) {
        selectedPeer = peer
        selectedRoom = nil
        onSelection?(peer)
        onRoomSelection?(nil)
    }

    func select(_ room: Room?) {
        selectedRoom = room
        selectedPeer = nil
        onRoomSelection?(room)
        onSelection?(nil)
    }

    func refresh() async {
        do {
            let status = try await client.status()
            ready = status.ready
            identityName = status.identityName
            endpointTicket = try await client.statusTicket()
            peers = try await client.peers()
            rooms = try await client.rooms()
            identities = await loadIdentities()
            statusText = ready ? "Connected" : "Daemon not ready"
        } catch {
            statusText = error.localizedDescription
        }
        onUpdate?()
    }

    func useIdentity(_ name: String) async {
        guard let active = identities.first(where: { $0.name == name }), !active.active else { return }
        guard LiveCall.shared.state == .idle, VideoCall.shared.state == .idle else {
            ChatStore.shared.onBanner?("End the active call before switching identity")
            return
        }
        selectedPeer = nil
        selectedRoom = nil
        onSelection?(nil)
        onRoomSelection?(nil)
        ChatStore.shared.switchIdentity(to: name)
        await refresh()
    }

    func createIdentity(_ name: String) async {
        guard LiveCall.shared.state == .idle, VideoCall.shared.state == .idle else {
            ChatStore.shared.onBanner?("End the active call before switching identity")
            return
        }
        do {
            _ = try await client.request(method: "identity.create", params: ["name": AnyEncodable(name)])
            ChatStore.shared.switchIdentity(to: name)
            selectedPeer = nil
            selectedRoom = nil
            onSelection?(nil)
            onRoomSelection?(nil)
            await refresh()
        } catch {
            addError = error.localizedDescription
            onUpdate?()
        }
    }

    private func loadIdentities() async -> [IdentityInfo] {
        let rawResult: AnyEncodable? = try? await client.request(method: "identities")
        guard let raw = rawResult, let list = raw["identities"]?.asArray else {
            return []
        }
        let decoder = JSONDecoder()
        guard let data = try? JSONEncoder().encode(list) else { return [] }
        struct RawIdentity: Decodable {
            let id: String
            let name: String
            let active: Bool
        }
        return (try? decoder.decode([RawIdentity].self, from: data))?
            .map { IdentityInfo(id: $0.id, name: $0.name, active: $0.active) } ?? []
    }

    @discardableResult
    func addChannel(name: String, ticketJSON: String) async -> String? {
        addError = nil
        do {
            let identity = try await client.identityId()
            try await client.addChannel(name: name, ticketJSON: ticketJSON, identity: identity)
            peers = try await client.peers()
        } catch {
            addError = error.localizedDescription
        }
        onUpdate?()
        return addError
    }

    /// GUI's "Issue receive ticket": a signed capability ticket covering
    /// message receive + live audio subscribe (native/src/core.ts
    /// capabilityTicketPayload).
    func issueCapabilityTicket() async -> String? {
        do {
            let identity = try await client.identityId()
            let result: AnyEncodable? = try await client.request(method: "capability.ticket", params: [
                "identity": AnyEncodable(identity),
                "capabilities": AnyEncodable([AnyEncodable("message.receive"), AnyEncodable("live.audio.subscribe")]),
            ])
            return result?["ticket"]?.stringValue
        } catch {
            return error.localizedDescription
        }
    }
}

/// Right pane that swaps between the empty placeholder and the chat for the
/// selected peer.
final class DetailContainerViewController: NSViewController {
    private let app: AppModel
    private var chat: ChatViewController?

    /// The chat currently shown, for automation (`Automation.swift`).
    var currentChat: ChatViewController? { chat }

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        app.onSelection = { [weak self] peer in self?.show(peer) }
        app.onRoomSelection = { [weak self] room in self?.show(room) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Initial placeholder (show(_:) only fires on selection changes).
        show(app.selectedPeer)
    }

    override func loadView() {
        view = NSView()
    }

    func replace(with next: NSViewController?) {
        for current in children { current.removeFromParent() }
        view.subviews.forEach { $0.removeFromSuperview() }
        guard let next else { return }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func show(_ peer: Peer?) {
        if let peer {
            let next = ChatViewController(peer: peer, app: app)
            chat = next
            replace(with: next)
        } else if app.selectedRoom == nil {
            chat = nil
            replace(with: PlaceholderViewController())
        }
    }

    private func show(_ room: Room?) {
        guard let room else { return }
        let next = ChatViewController(room: room, app: app)
        chat = next
        replace(with: next)
    }
}

final class PlaceholderViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "No channels")
        label.isSelectable = false
        label.textColor = .secondaryLabelColor
        let caption = NSTextField(labelWithString: "Add a channel with the peer's endpoint-addr ticket.")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [label, caption])
        stack.orientation = .vertical
        stack.spacing = 6
        view = NSView()
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
