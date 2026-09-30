import AppKit
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
        } else {
            body = content
            contentType = mime
        }
        let headers = [
            "Content-Type": contentType,
            "Content-Length": "\(body.count)",
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
/// blocked. HTML renders as itself; other media is wrapped in a minimal shell.
final class SandboxedArtifactWebView: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {
    private var handler: ArtifactSchemeHandler!
    /// Reports the clicked element as a text range over the artifact's source
    /// bytes, so the existing text resolver handles it (no HTML parser needed).
    var onElementSelection: ((ArtifactSelector) -> Void)?

    init(data: Data, mime: String, frame: NSRect = NSRect(x: 0, y: 0, width: 660, height: 460)) {
        let handler = ArtifactSchemeHandler()
        handler.content = data
        handler.mime = mime
        if !Self.rendersAsDocument(mime) {
            handler.shell = Self.shell(mime: mime)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: ArtifactSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        super.init(frame: frame, configuration: configuration)
        self.handler = handler
        configuration.userContentController.add(self, name: "idfonSelect")
        navigationDelegate = self
        allowsLinkPreview = false
        autoresizingMask = [.width, .height]
        addContentRules()
        load(URLRequest(url: URL(string: "\(ArtifactSchemeHandler.scheme)://artifact/index.html")!))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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

    private func addContentRules() {
        // Block first, then whitelist: `ignore-previous-rules` only undoes
        // blocks that appear *before* it. With the block last, the document
        // itself was blocked and the web view rendered blank.
        let json = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^idfon-artifact://"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "idfon-artifact-block-v2", encodedContentRuleList: json
        ) { [weak self] list, _ in
            guard let list else { return }
            self?.configuration.userContentController.add(list)
        }
    }

    /// Toggle click-to-select. While off, the page stays interactive.
    func setSelectionMode(_ on: Bool) {
        evaluateJavaScript("window.__idfonSelectMode = \(on ? "true" : "false");")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.scheme == ArtifactSchemeHandler.scheme ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "idfonSelect",
              let body = message.body as? [String: Any],
              let start = body["start"] as? NSNumber,
              let end = body["end"] as? NSNumber else { return }
        onElementSelection?(.text(
            start: start.uint64Value,
            end: end.uint64Value,
            quote: body["quote"] as? String))
    }

    private static let selectionScript = """
    window.__idfonSelectMode = false;
    document.addEventListener('click', function (event) {
      if (!window.__idfonSelectMode) return;
      event.preventDefault();
      event.stopPropagation();
      var el = event.target;
      if (!el || !el.outerHTML) return;
      var full = document.documentElement.outerHTML;
      var outer = el.outerHTML;
      var index = full.indexOf(outer);
      if (index < 0) return;
      var encoder = new TextEncoder();
      var start = encoder.encode(full.slice(0, index)).length;
      var end = start + encoder.encode(outer).length;
      var quote = (el.innerText || el.textContent || '').slice(0, 4000);
      window.webkit.messageHandlers.idfonSelect.postMessage({ start: start, end: end, quote: quote });
    }, true);
    """
}
