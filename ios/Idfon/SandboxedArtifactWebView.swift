import UIKit
import WebKit

/// Serves artifact bytes to the web view from memory under a private scheme,
/// so content never touches the filesystem or the network.
private final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "idfon-artifact"

    var content = Data()
    var mime = "application/octet-stream"
    /// HTML shell for non-HTML artifacts; nil means the content is the document.
    var shell: String?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let isDocument = url.path == "/index.html" || url.path.isEmpty || url.path == "/"
        let body: Data
        let contentType: String
        if isDocument, let shell {
            body = Data(shell.utf8)
            contentType = "text/html; charset=utf-8"
        } else if isDocument {
            body = content
            contentType = mime
        } else {
            body = content
            contentType = mime
        }
        let headers = [
            "Content-Type": contentType,
            "Content-Length": "\(body.count)",
            // Belt and suspenders with the content rule list.
            "Content-Security-Policy": "default-src 'none'; img-src data: idfon-artifact:; media-src data: idfon-artifact:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src idfon-artifact:",
        ]
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A locked-down web view for untrusted artifact content: non-persistent data
/// store, no native bridge, and every load except the in-memory artifact bytes
/// blocked. HTML renders as itself; other media is wrapped in a minimal shell so
/// the browser renders it as-is.
final class SandboxedArtifactWebView: WKWebView, WKNavigationDelegate {
    private var handler: ArtifactSchemeHandler!

    init(data: Data, mime: String) {
        let handler = ArtifactSchemeHandler()
        handler.content = data
        handler.mime = mime
        if !Self.rendersAsDocument(mime) {
            handler.shell = Self.shell(mime: mime)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Inline scripts are needed by generated charts; the shell CSP still
        // forbids any network origin.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // The handler must be registered on the configuration before the web
        // view is created.
        configuration.setURLSchemeHandler(handler, forURLScheme: ArtifactSchemeHandler.scheme)
        super.init(frame: .zero, configuration: configuration)
        self.handler = handler
        navigationDelegate = self
        allowsLinkPreview = false
        isOpaque = false
        addContentRules()
        load(URLRequest(url: URL(string: "\(ArtifactSchemeHandler.scheme)://artifact/index.html")!))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// HTML and SVG render as the document itself; everything else gets a shell.
    private static func rendersAsDocument(_ mime: String) -> Bool {
        mime.contains("html") || mime.contains("svg")
    }

    private static func shell(mime: String) -> String {
        let source = "\(ArtifactSchemeHandler.scheme)://artifact/content"
        let body: String
        if mime.hasPrefix("image/") {
            body = "<img src=\"\(source)\" alt=\"artifact\">"
        } else if mime.hasPrefix("video/") {
            body = "<video src=\"\(source)\" controls autoplay playsinline></video>"
        } else if mime.hasPrefix("audio/") {
            body = "<audio src=\"\(source)\" controls autoplay></audio>"
        } else {
            body = "<embed src=\"\(source)\" type=\"\(mime)\">"
        }
        return """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;height:100%;background:#111;color:#eee}
        body{display:flex;align-items:center;justify-content:center}
        img,video{max-width:100%;max-height:100%;object-fit:contain}
        embed{width:100%;height:100%;border:0}
        audio{width:90%}
        </style>
        \(body)
        """
    }

    /// Allow only the artifact scheme (and inline data:), block the rest.
    private func addContentRules() {
        let json = """
        [{"trigger":{"url-filter":"^idfon-artifact://"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "idfon-artifact-block", encodedContentRuleList: json
        ) { [weak self] list, _ in
            guard let list else { return }
            self?.configuration.userContentController.add(list)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.scheme == ArtifactSchemeHandler.scheme ? .allow : .cancel)
    }
}
