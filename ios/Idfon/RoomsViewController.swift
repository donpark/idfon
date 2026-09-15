import UIKit

/// Room list and the deliberately small room-management surface. Room messages
/// use the same ChatStore/event stream as 1:1 messages; only the conversation
/// scope changes.
final class RoomsViewController: UITableViewController {
    private let client = DaemonClient()
    private var rooms: [Room] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Rooms"
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
        navigationController?.pushViewController(RoomChatViewController(room: rooms[indexPath.row]), animated: true)
    }
}

final class RoomChatViewController: UIViewController, UITableViewDataSource, UITextFieldDelegate, ChatStoreObserver {
    private let room: Room
    private let client = DaemonClient()
    private let table = UITableView()
    private let input = UITextField()
    private var messages: [ChatMessage] = []

    init(room: Room) { self.room = room; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = room.name?.isEmpty == false ? room.name : "Room"
        view.backgroundColor = .systemBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        input.translatesAutoresizingMaskIntoConstraints = false
        input.placeholder = "Message room"
        input.borderStyle = .roundedRect
        input.delegate = self
        let send = UIButton(type: .system)
        send.translatesAutoresizingMaskIntoConstraints = false
        send.setTitle("Send", for: .normal)
        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        view.addSubview(table); view.addSubview(input); view.addSubview(send)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            input.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 8), input.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), input.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            send.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8), send.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), send.centerYAnchor.constraint(equalTo: input.centerYAnchor), send.widthAnchor.constraint(equalToConstant: 52)
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Copy Invite", style: .plain, target: self, action: #selector(copyInviteTapped)),
            UIBarButtonItem(title: "Leave", style: .plain, target: self, action: #selector(leaveTapped)),
        ]
        ChatStore.shared.addObserver(self)
        sync()
    }

    private func sync() { messages = ChatStore.shared.messages(in: room.id); table.reloadData(); if !messages.isEmpty { table.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false) } }
    func chatStoreDidUpdate() { sync() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath); let m = messages[indexPath.row]; cell.textLabel?.text = (m.outgoing ? "You: " : "\(m.peerId.prefix(8)): ") + m.displayText; cell.textLabel?.numberOfLines = 0; return cell }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { sendTapped(); return true }
    @objc private func sendTapped() {
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        input.text = ""
        let message = ChatMessage(id: UUID().uuidString, peerId: ChatStore.shared.selfPeerId, kind: .text(text), outgoing: true, timestamp: Date(), conversation: room.id)
        ChatStore.shared.appendOutgoing(message)
        Task { try? await client.sendRoom(room.id, text: text) }
    }
    @objc private func copyInviteTapped() {
        UIPasteboard.general.string = room.id
        let alert = UIAlertController(title: "Invite copied", message: "Share this room id with a member: \(room.id)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func leaveTapped() {
        let alert = UIAlertController(title: "Leave room?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in guard let self else { return }; Task { try? await self.client.leaveRoom(self.room.id); self.navigationController?.popViewController(animated: true) } })
        present(alert, animated: true)
    }
}
