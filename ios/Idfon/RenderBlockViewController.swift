import UIKit

/// A render block full-screen: the thread row carries the gist, the live tree
/// needs the room (and its actions need the catalog).
///
/// The spec is data. Every component comes from this app's catalog
/// (`JSONRenderSpec.catalog`) and every action from `RenderTools`; the agent
/// supplies neither code nor names that resolve to anything on its own
/// (`docs/reply-blocks.md`, `docs/idfon-edge.md` §P5).
///
/// shortcut: the sensitive-tool confirm and result sheet repeat what
/// `ArtifactDetailViewController` does; merge them into one render host when a
/// third consumer appears.
final class RenderBlockViewController: UIViewController {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = renderTitle ?? "View"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf))

        let render = JSONRenderView(spec: spec)
        render.onAction = { [weak self] action, args in
            self?.dispatch(action, args)
        }
        render.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(render)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            render.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            render.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            render.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            render.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func dismissSelf() {
        navigationController?.popViewController(animated: true)
        if navigationController == nil { dismiss(animated: true) }
    }

    /// Resolve an action against the app's catalog, confirming a sensitive one
    /// first. An unknown action is reported, never run.
    private func dispatch(_ action: String, _ args: [String: JSONValue]) {
        tools.confirm = { [weak self] tool in
            guard let self else { return false }
            return await withCheckedContinuation { continuation in
                let alert = UIAlertController(
                    title: tool.name,
                    message: tool.description.isEmpty ? "Run this action?" : tool.description,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Run", style: .default) { _ in continuation.resume(returning: true) })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
                self.present(alert, animated: true)
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
            let alert = UIAlertController(title: action, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
