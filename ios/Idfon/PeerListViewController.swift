import UIKit

/// Recents uses the same conversation model as rooms and direct chats.
final class ConversationsViewController: UITableViewController, ChatStoreObserver {
    private let client = DaemonClient()
    private var peers: [Peer] = []
    private var rooms: [Room] = []
    private var conversations: [Conversation] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recents"
        let voice = UIBarButtonItem(
            image: UIImage(systemName: "waveform"),
            style: .plain,
            target: self,
            action: #selector(voiceEngineTapped)
        )
        voice.accessibilityLabel = "Voice engine"
        navigationItem.rightBarButtonItem = voice
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "conversation")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        ChatStore.shared.addObserver(self)
        refresh()
    }

    /// Global reply-voice backend: Kokoro (on-device) or Apple Built-in.
    @objc private func voiceEngineTapped() {
        let current = SpeechEngines.backend
        let alert = UIAlertController(
            title: "Voice engine",
            message: "Reply speech for on-device voice calls",
            preferredStyle: .actionSheet
        )
        for backend in TtsBackend.allCases {
            let title = backend == current ? "✓ \(backend.title)" : backend.title
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                SpeechEngines.setBackend(backend)
            })
        }
        let asr = SpeechEngines.asrBackend
        for backend in AsrBackend.allCases {
            let title = backend == asr ? "✓ Recognition: \(backend.title)" : "Recognition: \(backend.title)"
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                SpeechEngines.setAsrBackend(backend)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
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
            let nextPeers = await fetchedPeers ?? []
            let nextRooms = await fetchedRooms ?? []
            await MainActor.run {
                self.peers = nextPeers
                self.rooms = nextRooms
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
/// Detail (the chat thread) is pushed on this tab's own stack.
final class PeerListViewController: UITableViewController, UISearchResultsUpdating {
    private let client = DaemonClient()
    private let search = UISearchController(searchResultsController: nil)
    private var peers: [Peer] = [] {
        didSet { applyFilter() }
    }
    /// What the table shows: `peers`, narrowed by the search text.
    private var shownPeers: [Peer] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Contacts"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Identity", style: .plain, target: self, action: #selector(showIdentityPicker))
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
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
            guard let fetched = await client.whenReady({ try await client.peers() }) else { return }
            await MainActor.run { self.peers = fetched }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        applyFilter()
    }

    private func applyFilter() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Match everything the row displays, endpoint id included.
        shownPeers = query.isEmpty ? peers : peers.filter {
            $0.displayName.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || ($0.endpointId?.lowercased().contains(query) ?? false)
        }
        tableView.reloadData()
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
        config.secondaryText = peer.endpointId.map { String($0.prefix(16)) + "…" }
        cell.contentConfiguration = config
        // ⓘ opens the detail screen; the row itself still opens the chat.
        cell.accessoryType = .detailButton
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(peer: shownPeers[indexPath.row]), animated: true)
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        let detail = ContactDetailViewController(peer: shownPeers[indexPath.row])
        detail.onChanged = { [weak self] in self?.refresh() }
        navigationController?.pushViewController(detail, animated: true)
    }

    /// Swipe to delete a contact (and drop its provisioned capability ticket).
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let peer = shownPeers[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            Task {
                do {
                    try await self.client.removePeer(ref: peer.id)
                    CapabilityTickets.remove(for: peer.id)
                    ContactVoiceSelection.remove(for: peer.id)
                    ContactOnDeviceEngines.remove(for: peer.id)
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
