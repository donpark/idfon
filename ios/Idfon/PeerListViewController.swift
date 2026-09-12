import UIKit

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

    @objc private func refresh() {
        Task {
            defer { DispatchQueue.main.async { self.refreshControl?.endRefreshing() } }
            guard let fetched = try? await client.peers() else { return }
            await MainActor.run { self.peers = fetched }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        applyFilter()
    }

    private func applyFilter() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        shownPeers = query.isEmpty ? peers : peers.filter {
            $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
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
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(peer: shownPeers[indexPath.row]), animated: true)
    }
}
