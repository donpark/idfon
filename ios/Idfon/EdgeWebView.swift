import UIKit
import WebKit

/// A `WKWebView` pointed at the public edge for one peer resource
/// (`docs/idfon-web-hybrid-plan.md`, P4). A WebView cannot set request headers,
/// so the requester ticket is injected as a cookie for the edge domain before
/// the first load; the edge reads `idfon_ticket`. Uses a **non-persistent**
/// store so the credential is never written to disk.
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

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        guard let url = EdgeClient.shared.url(account: account, path: resourcePath),
              let cookie = EdgeClient.shared.sessionCookie else {
            webView.loadHTMLString("<p>Edge is not configured.</p>", baseURL: nil)
            return
        }
        // A WebView cannot set request headers, so the edge credential rides the
        // `idfon_ticket` cookie. Over plain HTTP (a self-hosted/LAN edge) WebKit
        // does not send a cookie to an IP-literal host, so also carry the ticket
        // as `?ticket=` (the edge accepts it). HTTPS keeps it cookie-only.
        var loadURL = url
        if url.scheme?.lowercased() != "https",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "ticket", value: EdgeClient.shared.ticket)]
            loadURL = components.url ?? url
        }
        // Set the cookie first: the load must carry it.
        config.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak webView] in
            DispatchQueue.main.async {
                webView?.load(URLRequest(url: loadURL))
            }
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
