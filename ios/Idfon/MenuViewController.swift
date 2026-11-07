import UIKit

/// A menu contact's navigation surface: the OPML outline on screen, one level
/// per push (docs/live-radio.md "Menu contact"). The screen carries the
/// choices; picking a show opens its station screen and hands its `show=` path
/// to `onPlay`, which dials the call that plays it.
final class MenuViewController: UITableViewController {
    private let entries: [MenuEntry]
    /// Menu path of this level's parent (`News/Morning`, "" at the root).
    private let prefix: String
    /// The contact the stations belong to (the station screen reads its call).
    private let peerID: String
    private let onPlay: (String) -> Void

    init(entries: [MenuEntry], prefix: String = "", peerID: String,
         onPlay: @escaping (String) -> Void) {
        self.entries = entries
        self.prefix = prefix
        self.peerID = peerID
        self.onPlay = onPlay
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MenuViewController is built in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if title == nil { title = "Menu" }
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "entry")
        let entry = entries[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = entry.title
        // The source is data to show (what would play), never a link to open.
        config.secondaryText = entry.source
        cell.contentConfiguration = config
        cell.accessoryType = entry.children.isEmpty ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        let segment = MenuDocument.segment(entry, at: indexPath.row)
        let path = prefix.isEmpty ? segment : "\(prefix)/\(segment)"
        if !entry.children.isEmpty {
            let child = MenuViewController(entries: entry.children, prefix: path, peerID: peerID, onPlay: onPlay)
            child.title = entry.title
            navigationController?.pushViewController(child, animated: true)
        } else if entry.isPlayable {
            // The station gets its own screen; the call starts playing it and
            // Back returns to this list (the chat stays below, never skipped).
            navigationController?.pushViewController(
                StationDetailViewController(entry: entry, peerID: peerID, show: path), animated: true)
            onPlay(path)
        }
    }
}
