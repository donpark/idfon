import UIKit

/// Opens one public-edge resource through the same origin/path sandbox as
/// artifact pages (`docs/idfon-edge.md`, P4). The HTTPS requester credential
/// is a host-only HttpOnly cookie in a **non-persistent** store.
final class EdgeWebView: UIViewController {
    private let account: String
    private let resourcePath: String

    init(account: String, resourcePath: String) {
        self.account = account
        self.resourcePath = resourcePath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = account
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        guard let url = EdgeClient.shared.url(account: account, path: resourcePath),
              let cookie = EdgeClient.shared.cookie(for: url) else {
            let message = UILabel(frame: view.bounds)
            message.text = "A configured HTTPS edge is required."
            message.textAlignment = .center
            message.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(message)
            return
        }
        let source = GatewayArtifactSource(route: .edge, url: url, cookie: cookie)
        let webView = SandboxedArtifactWebView(source: source)
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
