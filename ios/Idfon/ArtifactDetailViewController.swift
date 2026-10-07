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

    /// Draw an agent-pointed region, in the overlay's own coordinates.
    func highlight(_ rect: CGRect) {
        selection = rect
        shape.path = UIBezierPath(rect: rect).cgPath
    }

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
    /// The peer the artifact came from, when known. Enables a remote fetch
    /// through the gateway if the blob is not held locally.
    private let peerRef: String?
    private let client = DaemonClient()
    private let stack = UIStackView()
    private var body: UIView?
    private var sharedURL: URL?
    /// Bytes of the rendered artifact, for "Save to Shared".
    private var renderedData: Data?

    private var textView: UITextView?
    private var imageView: UIImageView?
    private var overlay: SelectionOverlay?
    private var webView: SandboxedArtifactWebView?
    private var selectButton: UIBarButtonItem?
    private var selectMode = false
    private var pendingElement: ArtifactSelector?
    private lazy var askButton = UIBarButtonItem(
        title: "Ask", style: .done, target: self, action: #selector(askTapped))
    private lazy var shareButton = UIBarButtonItem(
        barButtonSystemItem: .action, target: self, action: #selector(shareTapped))
    private lazy var saveButton = UIBarButtonItem(
        title: "Shared", style: .plain, target: self, action: #selector(saveToSharedTapped))

    /// Called with the selection when the user asks about part of the artifact,
    /// plus a PNG of the selected region when one was cropped.
    var onReference: ((ArtifactSelector, Data?) -> Void)?
    /// An agent-pointed selection (`IDFON-POINT/1`) to open with and highlight.
    var point: (selector: ArtifactSelector, note: String?)?
    private var pointApplied = false

    init(artifact: Artifact, peerRef: String? = nil) {
        self.artifact = artifact
        self.peerRef = peerRef
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if point != nil, !pointApplied, body != nil, view.bounds.width > 0 {
            pointApplied = true
            applyPoint()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = artifact.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(dismissSelf))
        askButton.isEnabled = false
        navigationItem.rightBarButtonItems = [askButton]
        NotificationCenter.default.addObserver(
            self, selector: #selector(edgeReconciled(_:)),
            name: EdgeClient.reconciledNotification, object: nil)

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
        message("Loading…")
        Task {
            // Shared-root artifacts render through the gateway (loopback first,
            // then the public edge): the web view loads the URL itself, so
            // relative subresources resolve and no bytes cross the app layer.
            if usesWebView, let peerRef,
               let source = await ArtifactGateway.source(
                   account: peerRef, path: "/fs/\(artifact.artifactId)") {
                await MainActor.run { self.renderGateway(source) }
                return
            }
            // If iOS suspends us mid-fetch, hand the resource to the edge's
            // background session so it finishes and renders on return.
            let handoff = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.handOffToEdge() }
            defer { NotificationCenter.default.removeObserver(handoff) }
            do {
                let data = try await self.loadBytes()
                await MainActor.run { self.render(data) }
            } catch {
                await MainActor.run { self.loadFailed(error) }
            }
        }
    }

    /// A failed foreground fetch: hand the shared-root resource to the edge's
    /// background session (it finishes even if iOS suspends the app), cache the
    /// result in `SessionStore`, and let the reconcile notification reload.
    private func loadFailed(_ error: Error) {
        guard let peerRef, EdgeClient.shared.isConfigured else {
            message("Could not load artifact: \(error.localizedDescription)")
            return
        }
        handOffToEdge()
        message("Fetching through the edge; it will appear when you return.")
    }

    /// Starts the edge background fetch for this artifact, if configured.
    private func handOffToEdge() {
        guard let peerRef, EdgeClient.shared.isConfigured else { return }
        try? EdgeClient.shared.fetchInBackground(
            account: peerRef, path: "/fs/\(artifact.artifactId)")
    }

    /// A background edge fetch for this artifact finished; display its bytes.
    @objc private func edgeReconciled(_ note: Notification) {
        guard let records = note.object as? [EdgeClient.ReconciledArtifact] else { return }
        let path = "/fs/\(artifact.artifactId)"
        guard let record = records.first(where: { $0.account == peerRef && $0.path == path }) else {
            return
        }
        render(record.data)
    }

    /// Local blob first; if it is unavailable (or there is no ticket) and the
    /// artifact came from a peer, fetch it over the gateway
    /// (`idfon://<peer>/fs/<artifact_id>`). `artifact_id` is a path in the
    /// producer's shared root (`session/folder/file.html`). The root is live, so
    /// nothing is cached: a file the owner deleted or renamed is gone on the
    /// next request.
    private func loadBytes() async throws -> Data {
        if let peerRef,
           let cached = SessionStore.shared.cachedArtifact(peer: peerRef, path: artifact.artifactId) {
            return cached
        }
        if let ticket = artifact.blobTicket,
           let data = try? await client.fetchBlob(ticket), !data.isEmpty {
            if let peerRef {
                SessionStore.shared.cacheArtifact(peer: peerRef, path: artifact.artifactId, data: data)
            }
            return data
        }
        guard let peerRef else {
            throw DaemonClient.DaemonError.request("artifact content is not available locally")
        }
        // Live shared-root fetch: direct P2P first, edge fallback (P4).
        return try await client.fetchResource(
            account: peerRef, path: "/fs/\(artifact.artifactId)")
    }

    /// HTML/SVG/PDF/media render in a web view; everything else natively.
    private var usesWebView: Bool {
        let mime = artifact.mime.lowercased()
        return artifact.kind == .html
            || mime.contains("html") || mime.contains("svg")
            || mime == "application/pdf"
            || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    /// Displays a web-ish artifact through the gateway. The gateway may be the
    /// identity's loopback one (direct, edge fallback) or the public edge.
    private func renderGateway(_ source: GatewayArtifactSource) {
        wireWebView(SandboxedArtifactWebView(source: source))
    }

    /// Shared web-view wiring: element selection + the Select toolbar item.
    private func wireWebView(_ web: SandboxedArtifactWebView) {
        web.onElementSelection = { [weak self] selector in
            self?.pendingElement = selector
            self?.askButton.isEnabled = true
        }
        setBody(web)
        web.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        webView = web
        selectButton = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(toggleSelectMode))
        navigationItem.rightBarButtonItems = [askButton, selectButton!]
    }

    private func render(_ data: Data) {
        if usesWebView {
            // A local (cached/blob) artifact still renders by injection.
            wireWebView(SandboxedArtifactWebView(data: data, mime: artifact.mime))
        } else if artifact.mime.hasPrefix("image/"), let image = UIImage(data: data) {
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

        renderedData = data
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent((artifact.title as NSString).lastPathComponent)
        if (try? data.write(to: url)) != nil {
            sharedURL = url
            var items = [askButton]
            if let selectButton { items.append(selectButton) }
            items.append(saveButton)
            items.append(shareButton)
            navigationItem.rightBarButtonItems = items
        }
    }

    /// Apply the agent's point once the body is laid out: image regions draw on
    /// the overlay, text selections/HTML highlights run in their view, and the
    /// caption pins above the artifact.
    private func applyPoint() {
        guard let point else { return }
        if let note = point.note, !note.isEmpty {
            let banner = UILabel()
            banner.numberOfLines = 0
            banner.font = .preferredFont(forTextStyle: .subheadline)
            banner.textColor = .label
            banner.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.15)
            banner.layer.cornerRadius = 8
            banner.layer.masksToBounds = true
            banner.text = "  \(note)  "
            stack.insertArrangedSubview(banner, at: 0)
        }
        switch point.selector {
        case .region(let x, let y, let width, let height, _):
            guard let imageView, let overlay, let image = imageView.image else { return }
            let imageRect = Self.displayedImageRect(image: image.size, in: imageView.bounds)
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            overlay.highlight(CGRect(
                x: imageRect.minX + CGFloat(x) * imageRect.width,
                y: imageRect.minY + CGFloat(y) * imageRect.height,
                width: CGFloat(width) * imageRect.width,
                height: CGFloat(height) * imageRect.height))
        case .text(let start, let end, _):
            if let textView { Self.selectBytes(textView, start: start, end: end) }
            else { webView?.point(point.selector) }
        case .element, .timeRange:
            webView?.point(point.selector)
        default:
            break
        }
    }

    /// Select a byte range in a text view (the selector offsets are UTF-8 bytes).
    private static func selectBytes(_ textView: UITextView, start: UInt64, end: UInt64) {
        guard let data = textView.text.data(using: .utf8) else { return }
        let clamp = { (value: UInt64) -> Int in Int(min(value, UInt64(data.count))) }
        let startByte = clamp(start)
        let endByte = max(startByte, clamp(end))
        let startUTF16 = String(decoding: data.prefix(startByte), as: UTF8.self).utf16.count
        let endUTF16 = String(decoding: data.prefix(endByte), as: UTF8.self).utf16.count
        let range = NSRange(location: startUTF16, length: max(0, endUTF16 - startUTF16))
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    /// Promotes the fetched artifact into the user-visible shared directory the
    /// daemon serves, so a granted peer can fetch it at `idfon://<account>/fs/…`.
    @objc private func saveToSharedTapped() {
        Task {
            // A gateway-rendered artifact has no local bytes; fetch on demand.
            var data = self.renderedData
            if data == nil, let peerRef = self.peerRef {
                data = try? await self.client.fetchResource(
                    account: peerRef, path: "/fs/\(self.artifact.artifactId)")
            }
            guard let data else { return }
            await MainActor.run { self.presentSaved(data) }
        }
    }

    @MainActor private func presentSaved(_ data: Data) {
        let title: String
        let detail: String?
        if let url = SharedFolder.save(data, name: artifact.title) {
            title = "Saved to Shared"
            detail = url.lastPathComponent
        } else {
            title = "Could not save to Shared"
            detail = nil
        }
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        askButton.isEnabled = textView.selectedRange.length > 0
    }

    @objc private func askTapped() {
        if let pendingElement {
            onReference?(pendingElement, nil)
            dismiss(animated: true)
            return
        }
        if let textView, textView.selectedRange.length > 0 {
            let ns = textView.text as NSString
            let range = textView.selectedRange
            let prefix = ns.substring(to: range.location)
            let selected = ns.substring(with: range)
            let start = UInt64(prefix.lengthOfBytes(using: .utf8))
            onReference?(.text(start: start, end: start + UInt64(selected.lengthOfBytes(using: .utf8)), quote: selected), nil)
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
            let width = min(unit(selection.width / imageRect.width), 1 - x)
            let height = min(unit(selection.height / imageRect.height), 1 - y)
            let preview = imageView.image.flatMap {
                Self.crop($0, to: CGRect(x: x, y: y, width: width, height: height))
            }
            onReference?(.region(x: x, y: y, width: width, height: height, page: nil), preview)
            dismiss(animated: true)
        }
    }

    /// Crops the source image to a normalized (top-left) region as PNG, so the
    /// agent can be handed the exact pixels rather than only coordinates.
    static func crop(_ image: UIImage, to region: CGRect) -> Data? {
        guard let cg = image.cgImage, region.width > 0, region.height > 0 else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let rect = CGRect(
            x: region.minX * width, y: region.minY * height,
            width: region.width * width, height: region.height * height
        ).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).pngData()
    }

    /// The image's rendered rect inside `bounds` for `contentMode = .scaleAspectFit`.
    static func displayedImageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    @objc private func toggleSelectMode() {
        selectMode.toggle()
        webView?.setSelectionMode(selectMode)
        selectButton?.title = selectMode ? "Selecting…" : "Select"
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
