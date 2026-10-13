import UIKit

/// Recents uses the same conversation model as rooms and direct chats.
final class ConversationsViewController: UITableViewController, ChatStoreObserver {
    private let client = DaemonClient()
    private var peers: [Peer] = []
    private var rooms: [Room] = []
    private var conversations: [Conversation] = []
    /// §5.4 list states (loading / empty / failed).
    private var listState: ListState = .loading

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "conversation")
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
            await MainActor.run {
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

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "conversation", for: indexPath)
        let chat = conversations[indexPath.row]
        var config = cell.defaultContentConfiguration()
        let unread = ChatStore.shared.unreadCount(for: chat)
        config.text = unread > 0 ? "\(chat.title) · \(unread)" : chat.title
        if let room = chat.room {
            config.secondaryText = "Room · \(room.members.count) members"
        } else {
            config.secondaryText = chat.peer?.endpointId.map { String($0.prefix(16)) + "…" }
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
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
/// D1: the row's default action opens the person screen (the relationship
/// hub); chat and call are reached from there. D7: All/Recents are filter
/// segments, not tabs.
final class PeerListViewController: UITableViewController, UISearchResultsUpdating {
    private let client = DaemonClient()
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
    enum ContactFilter { case all, recents }
    private var filter: ContactFilter = .all { didSet { applyFilter() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contacts"
        let identity = UIBarButtonItem(
            title: "Identity", style: .plain, target: self, action: #selector(showIdentityPicker))
        let edge = UIBarButtonItem(
            title: "Edge", style: .plain, target: self, action: #selector(showEdgeSettings))
        let relay = UIBarButtonItem(
            title: "Relay", style: .plain, target: self, action: #selector(showRelaySettings))
        navigationItem.rightBarButtonItems = [identity, edge, relay]
        // §5.4: Add contact enters here (identity fixed at add time, §11);
        // the on-device agent editor shares the add slot.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), menu: buildAddMenu())
        navigationItem.backButtonDisplayMode = .generic // show "Back", not the callee's name
        navigationController?.navigationBar.prefersLargeTitles = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "peer")
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
        let filters = UISegmentedControl(items: ["All", "Recents"])
        filters.selectedSegmentIndex = 0
        filters.addAction(UIAction { [weak self] action in
            guard let self else { return }
            self.filter = (action.sender as? UISegmentedControl)?.selectedSegmentIndex == 1 ? .recents : .all
        }, for: .valueChanged)
        filters.translatesAutoresizingMaskIntoConstraints = false
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
            await MainActor.run {
                self.identityNames = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0.name) })
                self.peers = OnDeviceAgents.shared.peers + (fetched ?? [])
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
        guard OnDeviceAgents.available else { return UIMenu(children: [contact]) }
        return UIMenu(children: [
            contact,
            UIAction(title: "On-Device Agent", image: UIImage(systemName: "cpu")) { [weak self] _ in
                self?.addOnDeviceAgent()
            },
        ])
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

    private func applyFilter() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // D7: Recents = contacts with a chat, most recent interaction first.
        let base: [Peer]
        switch filter {
        case .all:
            base = peers
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

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "peer", for: indexPath)
        var config = cell.defaultContentConfiguration()
        let peer = shownPeers[indexPath.row]
        config.text = peer.displayName
        // A8: the relationship's identity label is always visible; the
        // endpoint fragment is optional status.
        if OnDeviceAgent.id(fromPeerId: peer.id) != nil {
            config.secondaryText = "on-device"
        } else {
            let identityLabel = peer.identity.map { identityNames[$0] ?? $0 }
            let parts = [identityLabel, peer.endpointId.map { String($0.prefix(16)) + "…" }]
                .compactMap { $0 }
            config.secondaryText = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        cell.contentConfiguration = config
        return cell
    }

    /// D1: the row's default action opens the person screen; on-device agents
    /// keep their editor as the hub.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let peer = shownPeers[indexPath.row]
        if let id = OnDeviceAgent.id(fromPeerId: peer.id) {
            let editor = OnDeviceAgentEditorViewController(
                agent: OnDeviceAgents.shared.agent(id: id)) { [weak self] in self?.refresh() }
            navigationController?.pushViewController(editor, animated: true)
            return
        }
        let detail = ContactDetailViewController(peer: peer)
        detail.onChanged = { [weak self] in self?.refresh() }
        navigationController?.pushViewController(detail, animated: true)
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
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            Task {
                do {
                    try await self.client.removePeer(ref: peer.id)
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
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
