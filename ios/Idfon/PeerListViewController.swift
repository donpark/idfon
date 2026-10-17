import UIKit

/// Recents uses the same conversation model as rooms and direct chats.
final class ConversationsViewController: UITableViewController, ChatStoreObserver {
    private let client = IdfonClient()
    private var peers: [Peer] = []
    private var rooms: [Room] = []
    private var conversations: [Conversation] = []
    /// §5.4 list states (loading / empty / failed).
    private var listState: ListState = .loading

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        tableView.register(ListRowCell.self, forCellReuseIdentifier: ListRowCell.reuseID)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        ChatStore.shared.addObserver(self)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc private func refresh() {
        let client = self.client
        Task {
            async let fetchedPeers = client.whenReady { try await client.peers() }
            async let fetchedRooms = client.whenReady { try await client.rooms() }
            let nextPeers = await fetchedPeers
            let nextRooms = await fetchedRooms
            await MainActor.run { [self] in
                self.peers = nextPeers ?? []
                self.rooms = nextRooms ?? []
                if nextPeers == nil || nextRooms == nil {
                    self.listState = .failed { [weak self] in self?.refresh() }
                } else {
                    self.listState = .empty(symbol: "message", title: "No Conversations")
                }
                self.rebuild()
                self.refreshControl?.endRefreshing()
            }
        }
    }

    private func rebuild() {
        let peerByID = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, Conversation(peer: $0)) })
        let roomByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, Conversation(room: $0)) })
        conversations = ChatStore.shared.recentChatIDs.compactMap { roomByID[$0] ?? peerByID[$0] }
        tableView.reloadData()
        listState.apply(to: tableView, rows: conversations.count)
    }

    func chatStoreDidUpdate() { rebuild() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { conversations.count }

    /// §5.2 row anatomy: room identity · last-message preview · timestamp ·
    /// session indicators.
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ListRowCell.reuseID, for: indexPath) as! ListRowCell
        let chat = conversations[indexPath.row]
        let last = ChatStore.shared.messages(for: chat).last
        let unread = ChatStore.shared.unreadCount(for: chat)
        let secondary = [
            LiveActivityController.currentCallPeer == chat.id ? "● Live" : nil,
            last?.displayText,
        ].compactMap { $0 }
        cell.configure(avatar: chat.room?.icon ?? chat.title,
                       title: unread > 0 ? "\(chat.title) · \(unread)" : chat.title,
                       secondary: secondary.isEmpty ? nil : secondary.joined(separator: " · "),
                       time: ListRowCell.time(last?.timestamp))
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// §5.2 edit verbs: mark unread / delete — that is the whole verb set.
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let chat = conversations[indexPath.row]
        let unread = UIContextualAction(style: .normal, title: "Mark Unread") { [weak self] _, _, done in
            ChatStore.shared.markUnread(chat)
            self?.rebuild()
            done(true)
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(chat) { done($0) }
        }
        return UISwipeActionsConfiguration(actions: [delete, unread])
    }

    private func confirmDelete(_ chat: Conversation, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Delete this conversation?",
            message: "Its messages are removed from this device.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            ChatStore.shared.removeConversation(chat)
            self?.rebuild()
            done(true)
        })
        alert.popoverPresentationController?.sourceView = tableView
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch conversations[indexPath.row].kind {
        case .direct(let peer): navigationController?.pushViewController(ChatViewController(peer: peer), animated: true)
        case .room(let room): navigationController?.pushViewController(ChatViewController(room: room), animated: true)
        }
    }
}

/// Contacts tab: every known identity, searchable by display name or id.
/// Test notes: pressing a contact opens its chat (the person screen is on
/// the chat's title tap); the row Call button dials it. D7: Recents/All are
/// filter segments, not tabs — Recents leads and is the default.
final class PeerListViewController: UITableViewController, UISearchResultsUpdating {
    private let client = IdfonClient()
    private let search = UISearchController(searchResultsController: nil)
    private var peers: [Peer] = [] {
        didSet { applyFilter() }
    }
    /// What the table shows: `peers`, narrowed by filter and search text.
    private var shownPeers: [Peer] = []
    /// §5.4 list states (loading / empty / failed).
    private var listState: ListState = .loading
    /// Identity id → display name for the A8 row label.
    private var identityNames: [String: String] = [:]

    /// D7 filter segments. Favorites joins when pinned contacts exist; the
    /// segment count is the only change.
    enum ContactFilter { case all, favorites, recents }
    /// Test notes: Recents is the default filter.
    private var filter: ContactFilter = .recents { didSet { applyFilter() } }
    private let filters = UISegmentedControl()
    /// D7 pin order (drag-reordered in edit mode) — presentation state, local.
    private var pinOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "idfon.pins.order") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "idfon.pins.order") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contacts"
        // Test-notes chrome: Edit is left-most; + sits top-right where the
        // collapsed ⋯ (→ the "Identities" sheet) used to be. The Edge/Relay
        // settings and identity picker stay in code, hidden until we decide
        // what they are for.
        navigationItem.rightBarButtonItems = [
            // §5.4: Add contact enters here (identity fixed at add time, §11);
            // the on-device agent editor shares the add slot.
            UIBarButtonItem(image: UIImage(systemName: "plus"), menu: buildAddMenu()),
        ]
        navigationItem.leftBarButtonItems = [
            editButtonItem, // §5.1 edit mode: drag to reorder pinned + delete
        ]
        navigationItem.backButtonDisplayMode = .generic // show "Back", not the callee's name
        // Test notes: the title sits in the nav bar like Messages (no large
        // title header).
        tableView.register(ListRowCell.self, forCellReuseIdentifier: ListRowCell.reuseID)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search contacts"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        // D7 segmented filter strip: All | Recents (interacted-with, most
        // recent first). Favorites joins when pinned contacts exist.
        filters.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl else { return }
            switch control.titleForSegment(at: control.selectedSegmentIndex) {
            case "Favorites": self.filter = .favorites
            case "Recents": self.filter = .recents
            default: self.filter = .all
            }
        }, for: .valueChanged)
        filters.translatesAutoresizingMaskIntoConstraints = false
        syncFilterStrip()
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        header.addSubview(filters)
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            filters.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            filters.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            filters.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
        ])
        tableView.tableHeaderView = header
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    /// Edge URL + requester ticket, persisted through `EdgeClient` (P4).
    @objc private func showEdgeSettings() {
        let alert = UIAlertController(
            title: "Edge",
            message: "Public edge URL and requester ticket, persisted on this device.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://idfon.net"
            field.text = EdgeClient.shared.baseURL?.absoluteString
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "requester ticket"
            field.text = EdgeClient.shared.ticket
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            EdgeClient.clear()
        })
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let url = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ticket = alert?.textFields?.last?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty, !ticket.isEmpty else { return }
            EdgeClient.configure(url: url, ticket: ticket)
        })
        present(alert, animated: true)
    }

    /// Enterprise relay URL(s) + optional token, persisted and applied when the
    /// daemon starts (`RelaySettings`).
    @objc private func showRelaySettings() {
        let alert = UIAlertController(
            title: "Relay",
            message: "Enterprise iroh relay URL(s), comma-separated. Token is optional — prefer a relay that authorizes endpoint ids. Applied when the daemon starts.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://relay.idfon.net:8443"
            field.text = RelaySettings.urls
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "relay token (optional)"
            field.text = RelaySettings.token
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            RelaySettings.clear()
        })
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let urls = alert?.textFields?.first?.text ?? ""
            let token = alert?.textFields?.last?.text ?? ""
            RelaySettings.configure(urls: urls, token: token, relayOnly: RelaySettings.isRelayOnly)
        })
        present(alert, animated: true)
    }

    @objc private func showIdentityPicker() {
        let picker = IdentityPickerViewController()
        picker.onChanged = { [weak self] in self?.refresh() }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func refresh() {
        let client = self.client
        Task {
            defer { DispatchQueue.main.async { self.refreshControl?.endRefreshing() } }
            // Retry while the daemon finishes coming up, so a cold/crash start
            // does not leave Contacts empty with no way back but a manual pull.
            let fetched = await client.whenReady({ try await client.peers() })
            let identities = await client.whenReady({ try await client.identities() }) ?? []
            // On-device agents are local contacts (no daemon peer), so they are
            // added here whether or not the daemon answered.
            await MainActor.run { [self] in
                self.identityNames = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0.name) })
                self.peers = OnDeviceAgents.shared.peers + (fetched ?? [])
                self.syncFilterStrip()
                if fetched == nil {
                    self.listState = .failed { [weak self] in self?.refresh() }
                } else {
                    self.listState = .empty(symbol: "person.crop.circle", title: "No Contacts")
                }
                self.applyFilter()
            }
        }
    }

    /// §5.4 Add contact: pick the identity first (a constrained choice, P11) —
    /// the relationship's identity is fixed at add time (§11) — then the
    /// ticket form. The daemon grants the chat capabilities on add (A7's
    /// scope step; per-grant moderation UI is future work).
    private func buildAddMenu() -> UIMenu {
        let contact = UIMenu(title: "Add Contact", image: UIImage(systemName: "person.badge.plus"),
                             children: [UIDeferredMenuElement { [weak self] completion in
            Task {
                let identities = (try? await self?.client.identities()) ?? []
                let actions: [UIAction]
                if identities.isEmpty {
                    actions = [UIAction(title: "Add Contact") { [weak self] _ in
                        self?.addContact(identity: "default")
                    }]
                } else {
                    actions = identities.map { info in
                        UIAction(title: info.displayName) { [weak self] _ in
                            self?.addContact(identity: info.id)
                        }
                    }
                }
                await MainActor.run { completion(actions) }
            }
        }])
        let exchange = [
            UIAction(title: "Scan QR Code", image: UIImage(systemName: "qrcode.viewfinder")) { [weak self] _ in
                self?.scanCode()
            },
            UIAction(title: "My Card", image: UIImage(systemName: "qrcode")) { [weak self] _ in
                self?.showMyCard()
            },
        ]
        guard OnDeviceAgents.available else { return UIMenu(children: [contact] + exchange) }
        return UIMenu(children: [
            contact,
        ] + exchange + [
            UIAction(title: "On-Device Agent", image: UIImage(systemName: "cpu")) { [weak self] _ in
                self?.addOnDeviceAgent()
            },
        ])
    }

    /// Contact exchange (docs/contact-exchange.md): scan a peer's QR code.
    private func scanCode() {
        let scanner = QRScannerViewController()
        scanner.onCode = { [weak self] code in
            guard let self else { return }
            ContactExchange.handleScan(code, from: self) { self.refresh() }
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    /// Contact exchange: this identity's own card (QR + share + Save to Contacts).
    private func showMyCard() {
        present(UINavigationController(rootViewController: MyCardViewController()), animated: true)
    }

    private func addContact(identity: String) {
        let alert = UIAlertController(title: "Add Contact", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Name" }
        alert.addTextField {
            $0.placeholder = "Contact ticket (JSON)"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ticket = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !ticket.isEmpty else { return }
            Task {
                do {
                    try await self.client.addChannel(name: name, ticketJSON: ticket, identity: identity)
                    self.refresh()
                } catch {
                    let failure = UIAlertController(
                        title: "Contact failed", message: error.localizedDescription, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(failure, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func addOnDeviceAgent() {
        let editor = OnDeviceAgentEditorViewController(agent: nil) { [weak self] in self?.refresh() }
        navigationController?.pushViewController(editor, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        applyFilter()
    }

    /// D7: the Favorites segment joins when pinned contacts exist. Test notes:
    /// Recents leads and is the default; All moved to the trailing slot.
    private func syncFilterStrip() {
        let titles = peers.contains(where: \Peer.pinned)
            ? ["Recents", "Favorites", "All"] : ["Recents", "All"]
        guard filters.numberOfSegments != titles.count else { return }
        filters.removeAllSegments()
        for (index, title) in titles.enumerated() {
            filters.insertSegment(withTitle: title, at: index, animated: false)
        }
        filters.selectedSegmentIndex = 0
        filter = .recents
    }

    /// Pin-order bookkeeping: newly pinned sorts first.
    private func setPinned(_ pinned: Bool, for id: String) {
        var order = pinOrder
        order.removeAll { $0 == id }
        if pinned { order.insert(id, at: 0) }
        pinOrder = order
    }

    /// §5.1 edit mode: drag to reorder pinned (visible in the Favorites view).
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        filter == .favorites
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath,
                            to destinationIndexPath: IndexPath) {
        var visible = shownPeers
        let moved = visible.remove(at: sourceIndexPath.row)
        visible.insert(moved, at: destinationIndexPath.row)
        shownPeers = visible
        pinOrder = visible.map(\.id)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let peer = shownPeers[indexPath.row]
        Task { [weak self] in
            try? await self?.client.removePeer(ref: peer.id, identity: peer.identity)
            await MainActor.run { self?.refresh() }
        }
    }

    private func applyFilter() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // D7: Recents = contacts with a chat, most recent interaction first.
        let base: [Peer]
        switch filter {
        case .all:
            base = peers
        case .favorites:
            let order = pinOrder
            base = peers.filter(\.pinned).sorted {
                (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
            }
        case .recents:
            let order = Dictionary(uniqueKeysWithValues:
                ChatStore.shared.recentChatIDs.enumerated().map { ($1, $0) })
            base = peers
                .filter { order[$0.id] != nil }
                .sorted { order[$0.id]! < order[$1.id]! }
        }
        // Match everything the row displays, endpoint id included.
        shownPeers = query.isEmpty ? base : base.filter {
            $0.displayName.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || ($0.endpointId?.lowercased().contains(query) ?? false)
        }
        tableView.reloadData()
        // A search that matches nothing is its own emptiness (§5.4).
        if !query.isEmpty && shownPeers.isEmpty {
            ListState.empty(symbol: "magnifyingglass", title: "No Results").apply(to: tableView, rows: 0)
        } else {
            listState.apply(to: tableView, rows: shownPeers.count)
        }
    }

    // MARK: - Table view

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shownPeers.count
    }

    /// §5.1 row anatomy: avatar · name · identity label (A8) · optional status.
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ListRowCell.reuseID, for: indexPath) as! ListRowCell
        let peer = shownPeers[indexPath.row]
        let status = OnDeviceAgent.id(fromPeerId: peer.id) != nil
            ? "on-device"
            : peer.endpointId.map { String($0.prefix(16)) + "…" }
        let identityLabel = peer.identity.map { identityNames[$0] ?? $0 }
        let secondary = [identityLabel, status].compactMap { $0 }
        cell.configure(avatar: peer.displayName, title: peer.displayName,
                       secondary: secondary.isEmpty ? nil : secondary.joined(separator: " · "),
                       time: nil)
        cell.accessoryType = .disclosureIndicator
        // Test notes: the row's Call button (left of the chevron) is the same
        // as tapping the row, then pressing the chat's call button.
        // §5.1: the row Call verb is shown only on callable contacts (the call
        // profile: a deaf human or a voice-refusing agent takes no calls).
        if ContactCallProfiles.isCallable(peer.id) {
            cell.setCallAction { [weak self] in self?.openChat(peer, startCall: true) }
        } else {
            cell.setCallAction(nil)
        }
        return cell
    }

    /// Test notes: pressing a contact opens its chat, with its messages — not
    /// the person screen (that stays on the chat's title tap). Instant-call
    /// contacts dial the chat's call immediately.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let peer = shownPeers[indexPath.row]
        openChat(peer, startCall: peer.instantCall && ContactCallProfiles.isCallable(peer.id))
    }

    /// The chat surface; `startCall` runs the chat's own call routing.
    private func openChat(_ peer: Peer, startCall: Bool) {
        Automation.mark("call: contact row peer=\(peer.id) dial=\(startCall)")
        let chat = ChatViewController(peer: peer)
        navigationController?.pushViewController(chat, animated: true)
        if startCall { chat.startCall() }
    }

    /// Swipe to delete a contact (and drop its provisioned capability ticket).
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let peer = shownPeers[indexPath.row]
        // On-device agents: user ones can be deleted locally; the built-in AFM 3
        // cannot.
        if let id = OnDeviceAgent.id(fromPeerId: peer.id) {
            guard id != OnDeviceAgents.builtInId else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                OnDeviceAgents.shared.remove(id: id)
                self?.refresh()
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [delete])
        }
        // §5.1 edit verbs: pin/unpin (Favorites) + delete.
        let pin = UIContextualAction(style: .normal, title: peer.pinned ? "Unpin" : "Pin") { [weak self] _, _, done in
            guard let self else { return done(false) }
            Task {
                do {
                    try await self.client.updatePeerFlags(ref: peer.id, identity: peer.identity, pinned: !peer.pinned)
                    self.setPinned(!peer.pinned, for: peer.id)
                    await MainActor.run { self.refresh() }
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            Task {
                do {
                    try await self.client.removePeer(ref: peer.id, identity: peer.identity)
                    CapabilityTickets.remove(for: peer.id)
                    ContactVoiceSelection.remove(for: peer.id)
                    ContactOnDeviceEngines.remove(for: peer.id)
                    ContactVoiceTurnModes.remove(for: peer.id)
                    await MainActor.run { self.refresh() }
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [delete, pin])
    }
}
