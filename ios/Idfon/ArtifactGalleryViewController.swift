import UIKit

/// §14: the per-conversation artifact gallery — "that image from last week"
/// is findable without scrolling the timeline. Revision chains show once
/// (their latest revision). Entered from the person screen (§6).
// shortcut: files and voice memos are listed for findability only — their
// actions (fetch/share/play) live in the timeline rows; move them here when
// the gallery earns its own detail screen.
final class ArtifactGalleryViewController: UITableViewController {
    private let conversation: Conversation
    private var items: [ChatMessage] = []

    init(conversation: Conversation) {
        self.conversation = conversation
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Shared Artifacts"
        navigationItem.backButtonDisplayMode = .generic
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "artifact")
        reload()
    }

    private func reload() {
        let all = ChatStore.shared.messages(for: conversation)
        // §14: revision chains collapse to their latest, here too.
        var artifacts: [String: Artifact] = [:]
        for message in all {
            if case .artifact(let artifact) = message.kind { artifacts[artifact.artifactId] = artifact }
        }
        var latestByRoot: [String: String] = [:]
        for message in all {
            if case .artifact(let artifact) = message.kind {
                latestByRoot[artifact.revisionRoot { artifacts[$0] }] = message.id
            }
        }
        items = all.filter { message in
            switch message.kind {
            case .artifact(let artifact):
                return latestByRoot[artifact.revisionRoot { artifacts[$0] }] == message.id
            case .file, .recording:
                return true
            default:
                return false
            }
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "artifact", for: indexPath)
        let message = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        switch message.kind {
        case .artifact(let artifact):
            config.image = UIImage(systemName: artifact.kind.glyph)
            config.text = artifact.title
            config.secondaryText = "\(artifact.kind.rawValue) · "
                + ByteCountFormatter.string(fromByteCount: Int64(artifact.sizeBytes), countStyle: .file)
        case .file(_, let name, let sizeBytes, _):
            config.image = UIImage(systemName: "doc")
            config.text = name
            config.secondaryText = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        case .recording(_, let durationMs, _):
            config.image = UIImage(systemName: "waveform")
            config.text = "Voice message"
            config.secondaryText = String(format: "%d:%02d", Int(durationMs / 1000) / 60, Int(durationMs / 1000) % 60)
        default:
            break
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .artifact(let artifact) = items[indexPath.row].kind else { return }
        let detail = ArtifactDetailViewController(artifact: artifact,
                                                  peerRef: conversation.peer?.id ?? conversation.id)
        present(UINavigationController(rootViewController: detail), animated: true)
    }
}
