import UIKit

final class PeerListViewController: UITableViewController {
    private let client = DaemonClient()
    private var peers: [Peer] = [] {
        didSet { tableView.reloadData() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Peers"
        navigationController?.navigationBar.prefersLargeTitles = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "peer")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
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

    // MARK: - Table view

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        peers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "peer", for: indexPath)
        var config = cell.defaultContentConfiguration()
        let peer = peers[indexPath.row]
        config.text = peer.displayName
        config.secondaryText = peer.endpointId.map { String($0.prefix(16)) + "…" }
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(peer: peers[indexPath.row]), animated: true)
    }
}
