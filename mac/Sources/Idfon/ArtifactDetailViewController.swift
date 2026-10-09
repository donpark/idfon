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

    /// Draw an agent-pointed region (top-left coordinates, same as selection).
    func highlight(_ rect: CGRect) {
        selection = rect
        needsDisplay = true
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
    /// The peer the artifact came from, when known. Enables a remote fetch
    /// through the gateway if the blob is not held locally.
    private let peerRef: String?
    private let client = DaemonClient()
    private let renderTools = RenderTools.make()
    private let scroll = NSScrollView()
    private var rendered: NSView?
    private var textView: NSTextView?
    private var imageView: NSImageView?
    private var selectionView: SelectionView?
    private var webView: SandboxedArtifactWebView?
    private var selectButton: NSButton?
    private var selectMode = false
    private var pendingElement: ArtifactSelector?
    /// Bytes of the rendered artifact, for "Save to Shared".
    private var renderedData: Data?
    private lazy var askButton = NSButton(title: "Ask", target: self, action: #selector(askTapped))

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
        let select = NSButton(title: "Select", target: self, action: #selector(toggleSelectMode))
        select.bezelStyle = .rounded
        select.isHidden = true
        selectButton = select
        let saveToShared = NSButton(
            title: "Save to Shared", target: self, action: #selector(saveToSharedTapped))
        saveToShared.bezelStyle = .rounded

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [title, meta, scroll, askButton, select, saveToShared, done] {
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
            select.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            select.trailingAnchor.constraint(equalTo: askButton.leadingAnchor, constant: -8),
            saveToShared.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            saveToShared.trailingAnchor.constraint(equalTo: select.leadingAnchor, constant: -8),
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(edgeReconciled(_:)),
            name: EdgeClient.reconciledNotification, object: nil)
        load()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if point != nil, !pointApplied, rendered != nil, view.bounds.width > 0 {
            pointApplied = true
            applyPoint()
        }
    }

    /// Apply the agent's point once laid out: image regions draw on the
    /// overlay, text selections/HTML highlights run in their view, and the
    /// caption goes to the sheet subtitle.
    private func applyPoint() {
        guard let point else { return }
        if let note = point.note, !note.isEmpty { view.window?.subtitle = note }
        switch point.selector {
        case .region(let x, let y, let width, let height, _):
            guard let imageView, let selectionView, let image = imageView.image else { return }
            let imageRect = Self.displayedImageRect(image: image.size, in: imageView.bounds)
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            selectionView.highlight(CGRect(
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
    private static func selectBytes(_ textView: NSTextView, start: UInt64, end: UInt64) {
        guard let data = textView.string.data(using: .utf8) else { return }
        let clamp = { (value: UInt64) -> Int in Int(min(value, UInt64(data.count))) }
        let startByte = clamp(start)
        let endByte = max(startByte, clamp(end))
        let startUTF16 = String(decoding: data.prefix(startByte), as: UTF8.self).utf16.count
        let endUTF16 = String(decoding: data.prefix(endByte), as: UTF8.self).utf16.count
        let range = NSRange(location: startUTF16, length: max(0, endUTF16 - startUTF16))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
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
            // If the app resigns active mid-fetch, hand the resource to the
            // edge's background session so it finishes and renders on return.
            let handoff = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { _ in self.handOffToEdge() }
            defer { NotificationCenter.default.removeObserver(handoff) }
            do {
                let data = try await self.loadBytes()
                await MainActor.run { self.render(data) }
            } catch {
                await MainActor.run { self.loadFailed(error) }
            }
        }
    }

    /// HTML/SVG/PDF/media render in a web view; everything else natively.
    private var usesWebView: Bool {
        let mime = artifact.mime.lowercased()
        return artifact.kind == .html
            || mime.contains("html") || mime.contains("svg")
            || mime == "application/pdf"
            || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    /// The producer's `metadata.renderer` hint decides json-render; when it is
    /// absent, detection by parsing keeps legacy artifacts working.
    private func wantsJSONRender(_ data: Data) -> Bool {
        switch artifact.metadata?["renderer"]?.string {
        case "json-render": return true
        case nil: return (try? JSONRenderSpec.decode(data)) != nil
        default: return false
        }
    }

    /// Displays a web-ish artifact through the gateway (loopback or edge).
    private func renderGateway(_ source: GatewayArtifactSource) {
        let web = SandboxedArtifactWebView(source: source)
        wireWebCallbacks(web)
        setDocument(web)
        webView = web
    }

    /// Element selection + the Select toolbar item (shared by both web variants).
    private func wireWebCallbacks(_ web: SandboxedArtifactWebView) {
        web.onElementSelection = { [weak self] selector in
            self?.pendingElement = selector
            self?.askButton.isEnabled = true
        }
        selectButton?.isHidden = false
    }

    /// A failed foreground fetch: hand the shared-root resource to the edge's
    /// background session and let the reconcile notification render it.
    private func loadFailed(_ error: Error) {
        guard peerRef != nil, EdgeClient.shared.isConfigured else {
            message("Could not load artifact: \(error.localizedDescription)")
            return
        }
        handOffToEdge()
        message("Fetching through the edge; it will appear when you return.")
    }

    /// Starts the edge background fetch for this artifact, if configured.
    private func handOffToEdge() {
        guard let peerRef, EdgeClient.shared.isConfigured else {
            idfonLog("idfon edge: handoff skipped (peer=\(peerRef ?? "-") configured=\(EdgeClient.shared.isConfigured))")
            return
        }
        do {
            let task = try EdgeClient.shared.fetchInBackground(
                account: peerRef, path: "/fs/\(artifact.artifactId)")
            idfonLog("idfon edge: handed artifact to background fetch task=\(task)")
        } catch {
            idfonLog("idfon edge: handoff failed: \(error.localizedDescription)")
        }
    }

    /// A background edge fetch for this artifact finished; display its bytes.
    @objc private func edgeReconciled(_ note: Notification) {
        guard let records = note.object as? [EdgeClient.ReconciledArtifact] else { return }
        let path = "/fs/\(artifact.artifactId)"
        guard let record = records.first(where: { $0.account == peerRef && $0.path == path }) else { return }
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
        // Live shared-root fetch: never cached.
        return try await client.fetchRemoteResource(
            account: peerRef, path: "/fs/\(artifact.artifactId)")
    }

    private func render(_ data: Data) {
        renderedData = data
        let webMime = artifact.mime.lowercased()
        let usesWebView = artifact.kind == .html
            || webMime.contains("html") || webMime.contains("svg")
            || webMime == "application/pdf"
            || webMime.hasPrefix("audio/") || webMime.hasPrefix("video/")
        if usesWebView {
            let web = SandboxedArtifactWebView(data: data, mime: artifact.mime)
            web.onElementSelection = { [weak self] selector in
                self?.pendingElement = selector
                self?.askButton.isEnabled = true
            }
            setDocument(web)
            webView = web
            selectButton?.isHidden = false
        } else if artifact.mime.hasPrefix("image/"), let image = NSImage(data: data) {
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
        } else if wantsJSONRender(data),
                  let spec = try? JSONRenderSpec.decode(data),
                  let normalized = try? spec.normalized(),
                  !normalized.elements.isEmpty {
            // App-owned json-render: the artifact supplies only data; every
            // component and action resolves against this app.
            let render = JSONRenderView(spec: normalized)
            render.onAction = { [weak self] action, args in
                self?.runTool(action: action, args: args)
            }
            render.frame = NSRect(x: 0, y: 0, width: 660, height: max(render.fittingSize.height, 160))
            render.autoresizingMask = [.width]
            setDocument(render)
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

    /// Runs a JSON-render action against the app-owned tool catalog. Sensitive
    /// tools need a native confirmation; unknown names never execute.
    private func runTool(action: String, args: [String: JSONValue]) {
        renderTools.confirm = { [weak self] tool in
            guard let self else { return false }
            return await self.confirmTool(tool)
        }
        Task {
            let result = await renderTools.dispatch(action, args: args)
            await MainActor.run { self.showResult(result) }
        }
    }

    @MainActor private func confirmTool(_ tool: RenderTool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = tool.name
        alert.informativeText = "\(tool.description). Allow?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor private func showResult(_ result: Result<String, RenderError>) {
        let message: String
        switch result {
        case .success(let value): message = value
        case .failure(.unknown(let name)): message = "Unknown action \(name)"
        case .failure(.denied(let name)): message = "\(name) was not confirmed"
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        askButton.isEnabled = (textView?.selectedRange().length ?? 0) > 0
    }

    @objc private func askTapped() {
        if let pendingElement {
            onReference?(pendingElement, nil)
            dismiss(self)
            return
        }
        if let textView, textView.selectedRange().length > 0 {
            let ns = textView.string as NSString
            let range = textView.selectedRange()
            let prefix = ns.substring(to: range.location)
            let selected = ns.substring(with: range)
            let start = UInt64(prefix.lengthOfBytes(using: .utf8))
            onReference?(.text(start: start, end: start + UInt64(selected.lengthOfBytes(using: .utf8)), quote: selected), nil)
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
            let width = min(unit(selection.width / imageRect.width), 1 - x)
            let height = min(unit(selection.height / imageRect.height), 1 - y)
            let preview = imageView.image.flatMap {
                Self.crop($0, to: CGRect(x: x, y: y, width: width, height: height))
            }
            onReference?(.region(x: x, y: y, width: width, height: height, page: nil), preview)
            dismiss(self)
        }
    }

    /// Crops the source image to a normalized (top-left) region as PNG.
    static func crop(_ image: NSImage, to region: CGRect) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              region.width > 0, region.height > 0 else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let rect = CGRect(
            x: region.minX * width, y: region.minY * height,
            width: region.width * width, height: region.height * height
        ).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    /// The image's rendered rect inside `bounds` for scaleProportionallyUpOrDown.
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

    /// Promotes the fetched artifact into the user-visible shared directory the
    /// daemon serves, so a granted peer can fetch it at `idfon://<account>/fs/…`.
    @objc private func saveToSharedTapped() {
        if let data = renderedData {
            finishSave(data)
            return
        }
        // Gateway-rendered artifacts hold no bytes; fetch them on demand.
        guard let peerRef else {
            message("Still loading…")
            return
        }
        message("Fetching…")
        Task {
            do {
                let data = try await self.client.fetchResource(
                    account: peerRef, path: "/fs/\(artifact.artifactId)")
                await MainActor.run { self.finishSave(data) }
            } catch {
                await MainActor.run { self.message("Could not fetch: \(error.localizedDescription)") }
            }
        }
    }

    private func finishSave(_ data: Data) {
        guard let url = SharedFolder.save(data, name: artifact.title) else {
            message("Could not save to Shared")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Saved to Shared"
        alert.informativeText = url.path
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func doneTapped() {
        dismiss(self)
    }
}
