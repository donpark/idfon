import AppKit

/// A render block in a sheet: the thread row carries the gist, the live tree
/// needs the room (and its actions need the catalog).
///
/// The spec is data. Every component comes from this app's catalog
/// (`JSONRenderSpec.catalog`) and every action from `RenderTools`; the agent
/// supplies neither code nor names that resolve on their own
/// (`docs/reply-blocks.md`, `docs/idfon-edge.md` §P5).
///
/// shortcut: the sensitive-tool confirm and result sheet repeat what
/// `ArtifactDetailViewController` does; merge them into one render host when a
/// third consumer appears.
final class RenderBlockViewController: NSViewController {
    private let spec: JSONRenderSpec
    private let renderTitle: String?
    private let tools = RenderTools.make()

    init(title: String?, spec: JSONRenderSpec) {
        self.renderTitle = title
        self.spec = spec
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 520))

        let title = NSTextField(labelWithString: renderTitle ?? "View")
        title.font = NSFont.boldSystemFont(ofSize: 14)

        let render = JSONRenderView(spec: spec)
        render.onAction = { [weak self] action, args in
            self?.dispatch(action, args)
        }
        render.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = render
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.bezelStyle = .rounded
        close.translatesAutoresizingMaskIntoConstraints = false

        for subview in [title, scroll, close] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            // The document view drives its own height, this its width.
            render.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            render.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            render.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    @objc private func closeSheet() {
        presentingViewController?.dismiss(self)
    }

    /// Resolve an action against the app's catalog, confirming a sensitive one
    /// first. An unknown action is reported, never run.
    private func dispatch(_ action: String, _ args: [String: JSONValue]) {
        tools.confirm = { [weak self] tool in
            guard let self, let window = self.view.window else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert()
                alert.messageText = tool.name
                alert.informativeText = tool.description.isEmpty ? "Run this action?" : tool.description
                alert.addButton(withTitle: "Run")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        Task { @MainActor in
            let result = await tools.dispatch(action, args: args)
            let message: String
            switch result {
            case .success(let text): message = text
            case .failure(let error):
                switch error {
                case .unknown(let name): message = "This app has no action named \(name)."
                case .denied(let name): message = "\(name) was not allowed."
                }
            }
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = action
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            await alert.beginSheetModal(for: window)
        }
    }
}
