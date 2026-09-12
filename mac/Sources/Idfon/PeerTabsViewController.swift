import AppKit

/// The three tabbed peer lists (the iOS tab root: Favorites / Recents /
/// Contacts), as a mac-native `NSTabViewController` with segmented buttons.
///
/// Each tab owns its **own** search field and table, because a single section
/// can get long enough to need searching on its own — a shared box would also
/// filter the other sections' contents out of view.
final class PeerTabsViewController: NSTabViewController {
    private let favorites = PeerSectionViewController(section: .favorites)
    private let recents = PeerSectionViewController(section: .recents)
    private let contacts = PeerSectionViewController(section: .contacts)

    init(peersProvider: @escaping () -> [Peer],
         recentPeerIds: @escaping () -> [String],
         onSelect: @escaping (Peer) -> Void) {
        super.init(nibName: nil, bundle: nil)
        // Segmented buttons above the list (the closest AppKit analogue of
        // UITabBarController's bar), not the window toolbar.
        tabStyle = .segmentedControlOnTop
        for (section, label) in [(favorites, "Favorites"), (recents, "Recents"), (contacts, "Contacts")] {
            addChild(section) // NSTabViewController creates the matching item
            tabViewItem(for: section)?.label = label
            section.peersProvider = peersProvider
            section.recentPeerIdsProvider = recentPeerIds
            section.onSelect = onSelect
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tab labels, for `mac/Checks/PeerTabsCheck`.
    var tabLabels: [String] { tabViewItems.map(\.label) }

    /// The three sections, for `mac/Checks/PeerTabsCheck`.
    var sections: [PeerSectionViewController] { children.compactMap { $0 as? PeerSectionViewController } }

    /// Re-reads the peer list in every section (app updates + store changes).
    func refresh() {
        favorites.reload()
        recents.reload()
        contacts.reload()
    }
}

/// One tab: a searchable peer list. Row rendering and selection only; the peer
/// source comes from `peersProvider` so the section can't drift from AppModel.
final class PeerSectionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Section { case favorites, recents, contacts }

    private let section: Section
    var peersProvider: (() -> [Peer])?
    /// Peer ids with message history, newest first (injected so this view layer
    /// stays free of ChatStore/daemon dependencies).
    var recentPeerIdsProvider: (() -> [String])?
    var onSelect: ((Peer) -> Void)?

    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var shown: [Peer] = []
    private var query = ""

    init(section: Section) {
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var sectionTitle: String {
        switch section {
        case .favorites: return "Favorites"
        case .recents: return "Recents"
        case .contacts: return "Contacts"
        }
    }

    /// The peers this section shows, before the search filter.
    private func sectionPeers() -> [Peer] {
        let peers = peersProvider?() ?? []
        switch section {
        case .contacts:
            return peers
        case .recents:
            // Session-only: message bodies are memory-only, so this reflects the
            // current run (newest first).
            let recent = recentPeerIdsProvider?() ?? []
            return recent.compactMap { id in peers.first { $0.id == id } }
        case .favorites:
            return [] // no backing store yet (same placeholder as the iOS tab)
        }
    }

    override func loadView() {
        view = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search \(sectionTitle.lowercased())"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("peer"))
        column.title = sectionTitle
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 44
        table.style = .plain
        table.target = self
        table.action = #selector(rowClicked)
        table.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(scroll)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
        ])
    }

    /// Re-reads the source and re-applies the current query.
    func reload() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = sectionPeers()
        shown = q.isEmpty ? all : all.filter { peer in
            // Match everything the row displays, endpoint id included.
            peer.displayName.lowercased().contains(q)
                || peer.id.lowercased().contains(q)
                || (peer.endpointId?.lowercased().contains(q) ?? false)
        }
        emptyLabel.stringValue = emptyText(isSearching: !q.isEmpty)
        emptyLabel.isHidden = !shown.isEmpty
        table.reloadData()
    }

    /// Peers currently listed, for `mac/Checks/PeerTabsCheck`.
    var displayedPeers: [Peer] { shown }

    /// Applies a search query as if typed (for `mac/Checks/PeerTabsCheck`).
    func search(_ text: String) {
        query = text
        reload()
    }

    private func emptyText(isSearching: Bool) -> String {
        if isSearching { return "No matches" }
        switch section {
        case .favorites: return "No favorites yet"
        case .recents: return "No recent conversations"
        case .contacts: return "No connections yet"
        }
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        reload()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < shown.count else { return }
        onSelect?(shown[row])
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        onSelect?(shown[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let peer = shown[row]
        let cell = tableView.makeView(withIdentifier: .init("peerCell"), owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = .init("peerCell")

        let labels: [NSTextField]
        if cell.subviews.isEmpty {
            let name = NSTextField(labelWithString: "")
            let endpoint = NSTextField(labelWithString: "")
            cell.addSubview(name)
            cell.addSubview(endpoint)
            cell.textField = name
            for subview in cell.subviews { subview.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                endpoint.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                endpoint.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                endpoint.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            ])
            labels = [name, endpoint]
        } else {
            labels = cell.subviews.compactMap { $0 as? NSTextField }
        }
        labels[0].stringValue = peer.displayName
        labels[0].font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labels[0].lineBreakMode = .byTruncatingTail
        labels[1].stringValue = peer.endpointId ?? peer.id
        labels[1].font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        labels[1].textColor = .secondaryLabelColor
        labels[1].lineBreakMode = .byTruncatingMiddle
        labels[1].isSelectable = true
        return cell
    }
}
