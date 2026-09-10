import AppKit
import CIdfon

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

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
        ChatStore.shared.start()
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
        Task { await app.refresh() }
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

    private func buildWindow() {
        // Plain manual split: fixed sidebar, flexible detail. (NSSplitView-
        // Controller's sidebar item sizing fought with our root views.)
        let sidebar = SidebarViewController(app: app)
        let detail = DetailContainerViewController(app: app)
        let split = NSViewController()
        split.view = NSView()
        split.view.addSubview(sidebar.view)
        split.addChild(sidebar)
        split.view.addSubview(detail.view)
        split.addChild(detail)
        for child in [sidebar.view, detail.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: split.view.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            sidebar.view.widthAnchor.constraint(equalToConstant: 280),
            detail.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: 1),
            detail.view.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
            detail.view.topAnchor.constraint(equalTo: split.view.topAnchor),
            detail.view.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

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
    }

    private var window: NSWindow?

    /// Minimal menu bar with Quit and an Emergency Stop (halts all media).
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.title = "Idfon"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Idfon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let mediaMenu = NSMenu(title: "Media")
        let stop = NSMenuItem(title: "Emergency Stop", action: #selector(emergencyStop), keyEquivalent: "")
        stop.keyEquivalentModifierMask = [.command, .shift]
        mediaMenu.addItem(stop)
        let mediaItem = NSMenuItem()
        mediaItem.title = "Media"
        mediaItem.submenu = mediaMenu
        main.addItem(mediaItem)

        NSApp.mainMenu = main
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
    var ready = false
    var identityName = ""
    var endpointTicket = ""
    var statusText = "Connecting"
    var addError: String?

    /// Fired on the main queue whenever any of the above changed.
    var onUpdate: (() -> Void)?
    /// Fired when the selected peer changed (detail swap).
    var onSelection: ((Peer?) -> Void)?

    private(set) var selectedPeer: Peer?

    let client = DaemonClient()

    func select(_ peer: Peer?) {
        selectedPeer = peer
        onSelection?(peer)
    }

    func refresh() async {
        do {
            let status = try await client.status()
            ready = status.ready
            identityName = status.identityName
            endpointTicket = try await client.statusTicket()
            peers = try await client.peers()
            identities = await loadIdentities()
            statusText = ready ? "Connected" : "Daemon not ready"
        } catch {
            statusText = error.localizedDescription
        }
        onUpdate?()
    }

    func useIdentity(_ name: String) async {
        guard let active = identities.first(where: { $0.name == name }), !active.active else { return }
        ChatStore.shared.switchIdentity(to: name)
        await refresh()
    }

    func createIdentity(_ name: String) async {
        do {
            _ = try await client.request(method: "identity.create", params: ["name": AnyEncodable(name)])
            ChatStore.shared.switchIdentity(to: name)
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
    func addConnection(name: String, ticketJSON: String) async -> String? {
        addError = nil
        do {
            let identity = try await client.identityId()
            try await client.addConnection(name: name, ticketJSON: ticketJSON, identity: identity)
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
                "capabilities": AnyEncodable([AnyEncodable("message_receive"), AnyEncodable("live_audio_subscribe")]),
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

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        app.onSelection = { [weak self] peer in self?.show(peer) }
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
        } else {
            chat = nil
            replace(with: PlaceholderViewController())
        }
    }
}

final class PlaceholderViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "No connections")
        label.isSelectable = false
        label.textColor = .secondaryLabelColor
        let caption = NSTextField(labelWithString: "Add a connection with the peer's endpoint-addr ticket.")
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