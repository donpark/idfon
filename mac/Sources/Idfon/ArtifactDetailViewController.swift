import AppKit

/// Drag-to-select overlay for image artifacts. Flipped so the selection rect is
/// in top-left coordinates, matching the region selector's convention.
private final class SelectionView: NSView {
    private(set) var selection: CGRect = .zero
    private var start: NSPoint?
    var onSelectionChanged: ((CGRect) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
        onSelectionChanged?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selection.width > 0, selection.height > 0 else { return }
        NSColor.systemYellow.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: selection).fill()
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()
    }
}

/// Artifact detail sheet. The user can select a region of an image or a range
/// of text and ask about it; the selection is handed back as an
/// `ArtifactSelector` for the composer to attach as a reference.
final class ArtifactDetailViewController: NSViewController, NSTextViewDelegate {
    private let artifact: Artifact
    private let client = DaemonClient()
    private let scroll = NSScrollView()
    private var rendered: NSView?
    private var textView: NSTextView?
    private var imageView: NSImageView?
    private var selectionView: SelectionView?
    private lazy var askButton = NSButton(title: "Ask", target: self, action: #selector(askTapped))

    /// Called with the selection when the user asks about part of the artifact.
    var onReference: ((ArtifactSelector) -> Void)?

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
            + "\nDrag a region or select text, then Ask.")
        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.maximumNumberOfLines = 2

        askButton.bezelStyle = .rounded
        askButton.isEnabled = false
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [title, meta, scroll, askButton, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -160),
            done.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            askButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            askButton.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
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
            let overlay = SelectionView(frame: imageView.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onSelectionChanged = { [weak self] rect in
                self?.askButton.isEnabled = rect.width > 1 && rect.height > 1
            }
            imageView.addSubview(overlay)
            setDocument(imageView)
            self.imageView = imageView
            self.selectionView = overlay
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
            textView.delegate = self
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = text
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            setDocument(textView)
            self.textView = textView
        } else {
            message("No preview for \(artifact.mime) yet.")
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        askButton.isEnabled = (textView?.selectedRange().length ?? 0) > 0
    }

    @objc private func askTapped() {
        if let textView, textView.selectedRange().length > 0 {
            let ns = textView.string as NSString
            let range = textView.selectedRange()
            let prefix = ns.substring(to: range.location)
            let selected = ns.substring(with: range)
            let start = UInt64(prefix.lengthOfBytes(using: .utf8))
            onReference?(.text(start: start, end: start + UInt64(selected.lengthOfBytes(using: .utf8)), quote: selected))
            dismiss(self)
            return
        }
        if let imageView, let selectionView, selectionView.selection.width > 1, selectionView.selection.height > 1 {
            let imageRect = Self.displayedImageRect(image: imageView.image?.size ?? .zero, in: imageView.bounds)
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            let selection = selectionView.selection
            let unit = { (value: CGFloat) in min(max(Double(value), 0), 1) }
            let x = unit((selection.minX - imageRect.minX) / imageRect.width)
            let y = unit((selection.minY - imageRect.minY) / imageRect.height)
            onReference?(.region(
                x: x,
                y: y,
                width: min(unit(selection.width / imageRect.width), 1 - x),
                height: min(unit(selection.height / imageRect.height), 1 - y),
                page: nil))
            dismiss(self)
        }
    }

    /// The image's rendered rect inside `bounds` for scaleProportionallyUpOrDown.
    static func displayedImageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    @objc private func doneTapped() {
        dismiss(self)
    }
}
