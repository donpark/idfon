import UIKit

/// Read-only detail screen for an artifact: metadata always visible, plus a
/// renderer for the kinds the app can already preview (text and images).
/// Region selection and "ask about this" land on top of this screen.
final class ArtifactDetailViewController: UIViewController {
    private let artifact: Artifact
    private let client = DaemonClient()
    private let stack = UIStackView()
    private var body: UIView?
    private var sharedURL: URL?

    init(artifact: Artifact) {
        self.artifact = artifact
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = artifact.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(dismissSelf))

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        addMetadata()
        load()
    }

    private func addMetadata() {
        let header = UILabel()
        header.numberOfLines = 0
        header.font = .preferredFont(forTextStyle: .headline)
        header.text = artifact.title
        stack.addArrangedSubview(header)

        let meta = UILabel()
        meta.numberOfLines = 0
        meta.font = .preferredFont(forTextStyle: .footnote)
        meta.textColor = .secondaryLabel
        meta.text = "\(artifact.kind.rawValue) · \(artifact.mime) · "
            + ByteCountFormatter.string(fromByteCount: Int64(artifact.sizeBytes), countStyle: .file)
            + "\n\(artifact.artifactId)"
        stack.addArrangedSubview(meta)
    }

    private func setBody(_ view: UIView) {
        body?.removeFromSuperview()
        body = view
        stack.addArrangedSubview(view)
    }

    private func message(_ text: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.text = text
        setBody(label)
    }

    private func load() {
        guard let ticket = artifact.blobTicket else {
            message("This artifact has no stored content (live or pending).")
            return
        }
        message("Loading…")
        Task {
            do {
                let data = try await client.fetchBlob(ticket)
                await MainActor.run { self.render(data) }
            } catch {
                await MainActor.run { self.message("Could not load artifact: \(error.localizedDescription)") }
            }
        }
    }

    private func render(_ data: Data) {
        if artifact.mime.hasPrefix("image/"), let image = UIImage(data: data) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = true
            setBody(imageView)
            imageView.heightAnchor.constraint(
                equalTo: imageView.widthAnchor,
                multiplier: max(image.size.height / max(image.size.width, 1), 0.2)).isActive = true
        } else if let text = String(data: data, encoding: .utf8),
                  artifact.mime.hasPrefix("text/")
                    || artifact.mime.contains("json")
                    || artifact.mime.contains("yaml")
                    || artifact.kind == .document
                    || artifact.kind == .data
                    || artifact.kind == .html {
            let textView = UITextView()
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.text = text
            setBody(textView)
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        } else {
            message("No preview for \(artifact.mime) yet.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent((artifact.title as NSString).lastPathComponent)
        if (try? data.write(to: url)) != nil {
            sharedURL = url
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .action, target: self, action: #selector(shareTapped))
        }
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    @objc private func shareTapped(_ sender: UIBarButtonItem) {
        guard let sharedURL else { return }
        let activity = UIActivityViewController(activityItems: [sharedURL], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = sender
        present(activity, animated: true)
    }
}
