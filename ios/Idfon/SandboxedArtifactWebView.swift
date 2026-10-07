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
final class SandboxedArtifactWebView: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {
    private var handler: ArtifactSchemeHandler!
    /// Reports the clicked element as a text range over the artifact's source
    /// bytes, so the existing text resolver handles it (no HTML parser needed).
    var onElementSelection: ((ArtifactSelector) -> Void)?
    /// Gateway origin the source-loaded variant may navigate to, in addition to
    /// the in-memory artifact scheme. `nil` for byte-injected content.
    private var allowedOrigin: (scheme: String, host: String)?

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
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.add(self, name: "idfonSelect")
        self.handler = handler
        navigationDelegate = self
        allowsLinkPreview = false
        isOpaque = false
        addContentRules()
        load(URLRequest(url: URL(string: "\(ArtifactSchemeHandler.scheme)://artifact/index.html")!))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Loads the artifact from a **gateway** URL (`idfon://<peer>/fs/<path>`
    /// served by the loopback gateway or the public edge) instead of injecting
    /// bytes, so relative subresources resolve and the gateway does the fetch.
    /// Same sandbox: non-persistent store, no bridge, and only the gateway host
    /// (plus inline `data:`) may load.
    init(source: GatewayArtifactSource) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.add(self, name: "idfonSelect")
        navigationDelegate = self
        allowsLinkPreview = false
        isOpaque = false
        allowedOrigin = (source.url.scheme ?? "https", source.host)
        addContentRules(allowing: source.host)
        let load = { [weak self] in _ = self?.load(URLRequest(url: source.url)) }
        if let cookie = source.cookie {
            configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                DispatchQueue.main.async { load() }
            }
        } else {
            load()
        }
    }

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

    /// Allow only one gateway host (and inline data:), block the rest. Used by
    /// the gateway-loaded variant; the document and its relative subresources
    /// all live on that host.
    private func addContentRules(allowing host: String) {
        let escaped = NSRegularExpression.escapedPattern(for: host)
        let json = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^https?://\(escaped)[/:]"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "idfon-gateway-block-\(escaped)", encodedContentRuleList: json
        ) { [weak self] list, _ in
            guard let list else { return }
            self?.configuration.userContentController.add(list)
        }
    }

    /// Toggle click-to-select. While off, the page stays interactive.
    func setSelectionMode(_ on: Bool) {
        evaluateJavaScript("window.__idfonSelectMode = \(on ? "true" : "false");")
    }

    private var loaded = false
    private var pendingPoint: ArtifactSelector?

    /// Highlight an agent-pointed selection. Queued until the document loads.
    func point(_ selector: ArtifactSelector) {
        pendingPoint = selector
        applyPointIfReady()
    }

    private func applyPointIfReady() {
        guard loaded, let selector = pendingPoint,
              let json = try? JSONEncoder().encode(selector) else { return }
        pendingPoint = nil
        let spec = String(decoding: json, as: UTF8.self)
        evaluateJavaScript("window.__idfonPoint(\(spec));")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyPointIfReady()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if url?.scheme == ArtifactSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }
        // The gateway-loaded variant navigates to the gateway origin (loopback
        // or edge); everything else is cancelled.
        if let origin = allowedOrigin, url?.scheme == origin.scheme, url?.host == origin.host {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
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
    window.__idfonPoint = function (spec) {
      try {
        document.querySelectorAll('.__idfon_point').forEach(function (e) { e.classList.remove('__idfon_point'); });
        if (!spec || spec.type === 'whole') return false;
        if (spec.type === 'time_range') {
          var media = document.querySelector('video,audio');
          if (media) { media.currentTime = (spec.start_ms || 0) / 1000; if (media.play) media.play(); }
          return !!media;
        }
        if (spec.type === 'region') {
          var box = document.createElement('div');
          box.className = '__idfon_point';
          box.style.cssText = 'position:fixed;left:' + (spec.x * 100) + '%;top:' + (spec.y * 100) +
            '%;width:' + (spec.width * 100) + '%;height:' + (spec.height * 100) +
            '%;border:3px solid #ffcc00;background:rgba(255,204,0,.25);pointer-events:none;z-index:2147483647';
          document.body.appendChild(box);
          return true;
        }
        var needle = (spec.quote || '').trim();
        if (!needle) return false;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var node;
        while ((node = walker.nextNode())) {
          var at = node.nodeValue.indexOf(needle);
          if (at < 0) continue;
          var range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + needle.length);
          var mark = document.createElement('mark');
          mark.className = '__idfon_point';
          mark.style.background = 'rgba(255,204,0,.5)';
          try { range.surroundContents(mark); } catch (e) { return false; }
          mark.scrollIntoView({ block: 'center' });
          return true;
        }
        return false;
      } catch (e) { return false; }
    };
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
