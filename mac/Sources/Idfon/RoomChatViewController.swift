import AppKit

/// Room chat deliberately reuses ChatStore rather than creating a second
/// history pipeline. The conversation id is the room id; sender peer ids stay
/// on each message for attribution.
final class RoomChatViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, ChatStoreObserver {
    private let room: Room
    private let client = DaemonClient()
    private let table = NSTableView()
    private let input = NSTextField()
    private var messages: [ChatMessage] = []

    init(room: Room) { self.room = room; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message")); table.addTableColumn(column); table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight =  thirty
        input.placeholderString = "Message room"; input.delegate = self; input.translatesAutoresizingMaskIntoConstraints = false
        let send = NSButton(title: "Send", target: self, action: #selector(sendTapped)); send.translatesAutoresizingMaskIntoConstraints = false
        let leave = NSButton(title: "Leave", target: self, action: #selector(leaveTapped)); leave.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSStackView(views: [input, send, leave]); bar.spacing = 8; bar.translatesAutoresizingMaskIntoConstraints = false
        view = NSView(); view.addSubview(scroll); view.addSubview(bar)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12), input.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)])
    }

    private var thirty: CGFloat { 30 }
    override func viewDidLoad() { super.viewDidLoad(); title = room.name?.isEmpty == false ? room.name! : "Room"; ChatStore.shared.addObserver(self); sync() }
    private func sync() { messages = ChatStore.shared.messages(in: room.id); table.reloadData(); if !messages.isEmpty { table.scrollRowToVisible(messages.count - 1) } }
    func chatStoreDidUpdate() { sync() }
    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let cell = NSTextField(labelWithString: ""); let m = messages[row]; cell.stringValue = "\(m.outgoing ? "You" : String(m.peerId.prefix(8))): \(m.displayText)"; cell.lineBreakMode = .byWordWrapping; return cell }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { if commandSelector == #selector(NSResponder.insertNewline(_:)) { sendTapped(); return true }; return false }
    @objc private func sendTapped() { let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; input.stringValue = ""; ChatStore.shared.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: ChatStore.shared.selfPeerId, kind: .text(text), outgoing: true, status: "Sent", timestamp: Date(), conversation: room.id)); Task { try? await client.sendRoom(room.id, text: text) } }
    @objc private func leaveTapped() { Task { try? await client.leaveRoom(room.id); ChatStore.shared.onBanner?("Left room") } }
}
