import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let peer: Peer
    private let client = DaemonClient()

    private let tableView = UITableView()
    private let composerField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let composerBar = UIView()
    private let callStatusLabel = UILabel()
    private var autoAnswerArmed = false

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

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "phone"), style: .plain, target: self, action: #selector(dialTapped)),
            UIBarButtonItem(image: UIImage(systemName: "phone.badge.waveform"), style: .plain, target: self, action: #selector(toggleAutoAnswer)),
        ]

        callStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        callStatusLabel.font = .preferredFont(forTextStyle: .callout)
        callStatusLabel.textColor = .secondaryLabel
        callStatusLabel.textAlignment = .center
        callStatusLabel.isHidden = true

        view.addSubview(tableView)
        composerBar.addSubview(composerField)
        composerBar.addSubview(sendButton)
        view.addSubview(composerBar)
        view.addSubview(callStatusLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composerBar.topAnchor),

            callStatusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            callStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            callStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),

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

        NotificationCenter.default.addObserver(forName: .init("idfon.dial"), object: nil, queue: .main) { [weak self] note in
            guard let ref = note.userInfo?["ref"] as? String else { return }
            self?.dial(peerRef: ref)
        }
        NotificationCenter.default.addObserver(forName: .init("idfon.answer"), object: nil, queue: .main) { [weak self] _ in
            self?.toggleAutoAnswer()
        }
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

    // MARK: - Live call

    private func showCallStatus(_ text: String?) {
        DispatchQueue.main.async {
            self.callStatusLabel.text = text
            self.callStatusLabel.isHidden = text == nil
        }
    }

    @objc private func dialTapped() {
        dial(peerRef: peer.id)
    }

    private func dial(peerRef: String) {
        NSLog("idfon dial: \(peerRef)")
        showCallStatus("Calling…")
        Task {
            do {
                try await LiveCall.dial(peer: peerRef, seconds: 8, client: client)
                showCallStatus("Call ended")
            } catch {
                showCallStatus("Call failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showCallStatus(nil) }
        }
    }

    /// Arms auto-answer: the daemon waits (up to 120s per attempt) for an
    /// incoming dial and records it. Disarming stops re-arming after the
    /// current attempt returns — the blocking request cannot be cancelled.
    @objc private func toggleAutoAnswer() {
        autoAnswerArmed.toggle()
        let armed = autoAnswerArmed
        navigationItem.rightBarButtonItems?.last?.isSelected = armed
        guard armed else { showCallStatus(nil); return }
        showCallStatus("Auto-answer armed…")
        Task {
            while self.autoAnswerArmed {
                do {
                    let out = try await LiveCall.armAutoAnswer(waitSeconds: 120, captureSeconds: 8, client: client)
                    guard self.autoAnswerArmed else { break }
                    self.showCallStatus("Call recorded")
                    NSLog("idfon call recorded to \(out)")
                } catch {
                    guard self.autoAnswerArmed else { break }
                    self.showCallStatus("Answer failed: \(error.localizedDescription)")
                }
            }
            if !self.autoAnswerArmed { self.showCallStatus(nil) }
        }
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
