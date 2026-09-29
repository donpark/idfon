import AppKit

/// Read-only artifact detail sheet: metadata plus a renderer for the kinds the
/// app can already preview (text and images). Region selection and "ask about
/// this" land on top of this.
final class ArtifactDetailViewController: NSViewController {
    private let artifact: Artifact
    private let client = DaemonClient()
    private let scroll = NSScrollView()
    private var rendered: NSView?

    init(artifact: Artifact) {
        self.artifact = artifact
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 720, height: 560)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))

        let title = NSTextField(labelWithString: artifact.title)
        title.font = NSFont.boldSystemFont(ofSize: 15)
        title.maximumNumberOfLines = 2
        let meta = NSTextField(labelWithString: "\(artifact.kind.rawValue) · \(artifact.mime) · "
            + ByteCountFormatter.string(fromByteCount: Int64(artifact.sizeBytes), countStyle: .file)
            + "\n\(artifact.artifactId)")
        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.maximumNumberOfLines = 2

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [title, meta, scroll, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -88),
            done.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            meta.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            meta.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()
    }

    private func setDocument(_ view: NSView) {
        rendered?.removeFromSuperview()
        rendered = view
        scroll.documentView = view
    }

    private func message(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 0, width: 660, height: 40)
        setDocument(label)
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
        if artifact.mime.hasPrefix("image/"), let image = NSImage(data: data) {
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            setDocument(imageView)
        } else if let text = String(data: data, encoding: .utf8),
                  artifact.mime.hasPrefix("text/")
                    || artifact.mime.contains("json")
                    || artifact.mime.contains("yaml")
                    || artifact.kind == .document
                    || artifact.kind == .data
                    || artifact.kind == .html {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 660, height: 400))
            textView.isEditable = false
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = text
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            setDocument(textView)
        } else {
            message("No preview for \(artifact.mime) yet.")
        }
    }

    @objc private func doneTapped() {
        dismiss(self)
    }
}
