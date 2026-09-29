import UIKit

/// Drag-to-select overlay for image artifacts. The selection rect is in the
/// overlay's own coordinates; the detail view normalizes it against the
/// displayed image rect.
private final class SelectionOverlay: UIView {
    private(set) var selection: CGRect = .zero
    private let shape = CAShapeLayer()
    private var start: CGPoint?
    var onSelectionChanged: ((CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.strokeColor = UIColor.systemYellow.cgColor
        shape.fillColor = UIColor.systemYellow.withAlphaComponent(0.2).cgColor
        shape.lineWidth = 2
        layer.addSublayer(shape)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handle(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            start = point
            selection = .zero
            shape.path = nil
        case .changed:
            guard let start else { return }
            selection = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y))
            shape.path = UIBezierPath(rect: selection).cgPath
            onSelectionChanged?(selection)
        default:
            break
        }
    }
}

/// Read-only detail screen for an artifact. The user can select a region of an
/// image or a range of text and ask about it; the selection is handed back as
/// an `ArtifactSelector` for the composer to attach as a reference.
final class ArtifactDetailViewController: UIViewController, UITextViewDelegate {
    private let artifact: Artifact
    private let client = DaemonClient()
    private let stack = UIStackView()
    private var body: UIView?
    private var sharedURL: URL?

    private var textView: UITextView?
    private var imageView: UIImageView?
    private var overlay: SelectionOverlay?
    private lazy var askButton = UIBarButtonItem(
        title: "Ask", style: .done, target: self, action: #selector(askTapped))
    private lazy var shareButton = UIBarButtonItem(
        barButtonSystemItem: .action, target: self, action: #selector(shareTapped))

    /// Called with the selection when the user asks about part of the artifact.
    var onReference: ((ArtifactSelector) -> Void)?

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
        askButton.isEnabled = false
        navigationItem.rightBarButtonItems = [askButton]

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

        let hint = UILabel()
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .tertiaryLabel
        hint.text = "Drag a region or select text, then Ask to attach it to your message."
        stack.addArrangedSubview(hint)
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
            let overlay = SelectionOverlay(frame: imageView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onSelectionChanged = { [weak self] rect in
                self?.askButton.isEnabled = rect.width > 1 && rect.height > 1
            }
            imageView.addSubview(overlay)
            setBody(imageView)
            imageView.heightAnchor.constraint(
                equalTo: imageView.widthAnchor,
                multiplier: max(image.size.height / max(image.size.width, 1), 0.2)).isActive = true
            self.imageView = imageView
            self.overlay = overlay
        } else if let text = String(data: data, encoding: .utf8),
                  artifact.mime.hasPrefix("text/")
                    || artifact.mime.contains("json")
                    || artifact.mime.contains("yaml")
                    || artifact.kind == .document
                    || artifact.kind == .data
                    || artifact.kind == .html {
            let textView = UITextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.delegate = self
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.text = text
            setBody(textView)
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            self.textView = textView
        } else {
            message("No preview for \(artifact.mime) yet.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent((artifact.title as NSString).lastPathComponent)
        if (try? data.write(to: url)) != nil {
            sharedURL = url
            navigationItem.rightBarButtonItems = [askButton, shareButton]
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        askButton.isEnabled = textView.selectedRange.length > 0
    }

    @objc private func askTapped() {
        if let textView, textView.selectedRange.length > 0 {
            let ns = textView.text as NSString
            let range = textView.selectedRange
            let prefix = ns.substring(to: range.location)
            let selected = ns.substring(with: range)
            let start = UInt64(prefix.lengthOfBytes(using: .utf8))
            onReference?(.text(start: start, end: start + UInt64(selected.lengthOfBytes(using: .utf8)), quote: selected))
            dismiss(animated: true)
            return
        }
        if let imageView, let overlay, overlay.selection.width > 1, overlay.selection.height > 1 {
            let imageRect = Self.displayedImageRect(image: imageView.image?.size ?? .zero, in: imageView.bounds)
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            let selection = overlay.selection
            let unit = { (value: CGFloat) in min(max(Double(value), 0), 1) }
            let x = unit((selection.minX - imageRect.minX) / imageRect.width)
            let y = unit((selection.minY - imageRect.minY) / imageRect.height)
            onReference?(.region(
                x: x,
                y: y,
                width: min(unit(selection.width / imageRect.width), 1 - x),
                height: min(unit(selection.height / imageRect.height), 1 - y),
                page: nil))
            dismiss(animated: true)
        }
    }

    /// The image's rendered rect inside `bounds` for `contentMode = .scaleAspectFit`.
    static func displayedImageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
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
