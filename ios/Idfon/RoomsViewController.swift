import UIKit

/// Room list. Room messages use the same ChatViewController and ChatStore as
/// direct chats; only the conversation scope and a few controls differ.
final class RoomsViewController: UITableViewController {
    private let client = DaemonClient()
    private var rooms: [Room] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Rooms"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Join", style: .plain, target: self, action: #selector(joinRoom))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addRoom))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "room")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc private func refresh() {
        Task {
            let result = try? await client.rooms()
            await MainActor.run {
                if let result { self.rooms = result; self.tableView.reloadData() }
                self.refreshControl?.endRefreshing()
            }
        }
    }

    @objc private func joinRoom() {
        let alert = UIAlertController(title: "Join Room", message: "Paste the room id and provide member peer ids.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Room id" }
        alert.addTextField { $0.placeholder = "Room name (optional)" }
        alert.addTextField { $0.placeholder = "peer-id, peer-id" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let room = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let members = (alert?.textFields?[2].text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !room.isEmpty else { return }
            Task {
                do { _ = try await self.client.joinRoom(room, name: name?.isEmpty == false ? name : nil, members: members); self.refresh() }
                catch { self.presentError(error) }
            }
        })
        present(alert, animated: true)
    }

    @objc private func addRoom() {
        let alert = UIAlertController(title: "New Room", message: "Add member peer ids separated by commas.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Room name (optional)" }
        alert.addTextField { $0.placeholder = "peer-id, peer-id" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let members = (alert?.textFields?[1].text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            Task {
                do { _ = try await self.client.createRoom(name: name?.isEmpty == false ? name : nil, members: members); self.refresh() }
                catch { self.presentError(error) }
            }
        })
        present(alert, animated: true)
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Room failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rooms.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "room", for: indexPath)
        let room = rooms[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = room.name?.isEmpty == false ? room.name : room.id
        config.secondaryText = "\(room.members.count) members"
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(room: rooms[indexPath.row]), animated: true)
    }
}
