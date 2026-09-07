import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let peer: Peer
    private let client = DaemonClient()

    private let tableView = UITableView()
    private let composerField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let composerBar = UIView()

    private var messages: [ChatMessage] = []

    init(peer: Peer) {
        self.peer = peer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = peer.displayName
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        tableView.separatorStyle = .none

        composerBar.translatesAutoresizingMaskIntoConstraints = false
        composerBar.backgroundColor = .secondarySystemBackground

        composerField.translatesAutoresizingMaskIntoConstraints = false
        composerField.borderStyle = .roundedRect
        composerField.placeholder = "Message"
        composerField.delegate = self
        composerField.returnKeyType = .send
        composerField.enablesReturnKeyAutomatically = true

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.contentMode = .scaleAspectFit
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        view.addSubview(tableView)
        composerBar.addSubview(composerField)
        composerBar.addSubview(sendButton)
        view.addSubview(composerBar)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composerBar.topAnchor),

            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerBar.heightAnchor.constraint(equalToConstant: 56),

            composerField.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 12),
            composerField.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            sendButton.leadingAnchor.constraint(equalTo: composerField.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: composerBar.centerYAnchor),
            composerField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
        ])

        ChatStore.shared.onUpdate = { [weak self] in self?.syncMessages() }
        syncMessages()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ChatStore.shared.onUpdate = nil
    }

    private func syncMessages() {
        messages = ChatStore.shared.messages.filter { $0.peerId == peer.id }
        tableView.reloadData()
        if !messages.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: true)
        }
    }

    @objc private func sendTapped() {
        guard let text = composerField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        composerField.text = nil
        ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peer.id, text: text, outgoing: true))
        Task { try? await client.sendText(to: peer.id, text) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return true
    }

    // MARK: - Table view

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath)
        let message = messages[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = message.text
        config.secondaryText = message.outgoing ? "sent" : "received"
        cell.contentConfiguration = config
        cell.isUserInteractionEnabled = false
        return cell
    }
}
