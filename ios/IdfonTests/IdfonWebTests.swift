import XCTest
import Network
import WebKit

@testable import Idfon

/// App-hosted unit tests for the hybrid web layer
/// (`docs/idfon-edge.md`): deep-link parsing, edge URL/cookie
/// construction, background-fetch bookkeeping, audit rotation, and json-render
/// normalization. Runs on a device with `xcodebuild test -scheme Idfon`.
@MainActor
private final class WebViewLoadProbe: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation

    init(finished: XCTestExpectation) {
        self.finished = finished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}

private final class LoopbackHTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let cookie: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "idfon.web-test-http")
    private let lock = NSLock()
    private var requests: [Request] = []
    private let page: String
    private let redirectPath: String
    private(set) var port: UInt16 = 0

    init(page: String = "", redirectPath: String = "/other-peer/fs/charts/redirected.txt") throws {
        self.page = page
        self.redirectPath = redirectPath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "LoopbackHTTPFixture", code: 1)
        }
        self.port = port
    }

    func stop() { listener.cancel() }

    func snapshot() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection else { return }
            self.receiveHeader(connection, accumulated: Data())
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let end = bytes.range(of: Data([13, 10, 13, 10])) {
                self.respond(connection, header: Data(bytes[..<end.lowerBound]))
            } else if !complete && error == nil {
                self.receiveHeader(connection, accumulated: bytes)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }
            .map { $0.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces) }
        lock.lock()
        requests.append(Request(path: path, cookie: cookie))
        lock.unlock()

        if path == "/peer/fs/charts/redirect" {
            let response = "HTTP/1.1 302 Found\r\nLocation: \(redirectPath)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = path == "/peer/fs/charts/index.html" ? page
            : (path == "/peer/fs/charts/ok.txt" ? "ok" : "secret")
        let response = "HTTP/1.1 200 OK\r\nContent-Type: \(path.hasSuffix(".html") ? "text/html" : "text/plain")\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class IdfonWebTests: XCTestCase {
    func testResourceDeepLinkParsesRefAndPath() throws {
        let link = try XCTUnwrap(IdfonURL(URL(string: "idfon://abc/fs/a.html")!))
        XCTAssertEqual(link, .resource(ref: "abc", path: ["fs", "a.html"]))
    }

    func testEndpointIdHostIsLowercasedAndPathPreserved() throws {
        let hex = String(repeating: "A", count: 64)
        let link = try XCTUnwrap(IdfonURL(URL(string: "idfon://\(hex)/Fs/A.html")!))
        XCTAssertEqual(link, .resource(ref: hex.lowercased(), path: ["Fs", "A.html"]))
    }

    func testReservedVerbsMatchCaseInsensitively() throws {
        XCTAssertEqual(try XCTUnwrap(IdfonURL(URL(string: "idfon://DIAL/peer")!)), .dial(ref: "peer"))
        XCTAssertEqual(try XCTUnwrap(IdfonURL(URL(string: "idfon://videoDial/p")!)), .videoDial(ref: "p"))
        XCTAssertEqual(try XCTUnwrap(IdfonURL(URL(string: "idfon://answer")!)), .answer)
        XCTAssertNil(IdfonURL(URL(string: "idfon://dial")!), "a verb with no ref is rejected")
    }

    func testNonIdfonSchemeRejected() {
        XCTAssertNil(IdfonURL(URL(string: "https://example.com/fs/a")!))
    }

    func testEdgeURLComposition() throws {
        EdgeClient.configure(url: "https://idfon.net/", ticket: "tok")
        let url = try XCTUnwrap(EdgeClient.shared.url(account: "acct", path: "/fs/a.html"))
        XCTAssertEqual(url.absoluteString, "https://idfon.net/acct/fs/a.html")
    }

    func testEdgeURLUsesZ32HostForEndpointIds() throws {
        // 64-hex endpoint id -> 52-char z-base-32 host (fits a DNS label).
        let hex = "ceb9651243ed51ae5504f830a41b1cc0d93d4e9ac7a776a41d4ecf004be6168f"
        let z32 = "34hskr1d7ie4hier9yakegahadcu4uw4a6uzpjy7j58oy19gn48o"
        XCTAssertEqual(EdgeClient.EndpointRefShort.fromHex(hex), z32)
        XCTAssertEqual(EdgeClient.EndpointRefShort.fromHex("acct"), nil)

        EdgeClient.configure(url: "https://idfon.net", ticket: "tok")
        let url = try XCTUnwrap(EdgeClient.shared.url(account: hex, path: "/fs/a.html"))
        XCTAssertEqual(url.absoluteString, "https://\(z32).idfon.net/fs/a.html")

        // An alias stays on the path form.
        let alias = try XCTUnwrap(EdgeClient.shared.url(account: "acct", path: "/fs/a.html"))
        XCTAssertEqual(alias.absoluteString, "https://idfon.net/acct/fs/a.html")

        // An IP base cannot take a wildcard subdomain: path form.
        EdgeClient.configure(url: "http://192.168.1.2:8791", ticket: "tok")
        let ip = try XCTUnwrap(EdgeClient.shared.url(account: hex, path: "/fs/a.html"))
        XCTAssertEqual(ip.absoluteString, "http://192.168.1.2:8791/\(hex)/fs/a.html")
    }

    func testRelaySettingsPrecedence() {
        RelaySettings.clear()
        RelaySettings.configureFromLaunchArgs([])
        XCTAssertFalse(RelaySettings.isConfigured)
        XCTAssertNil(RelaySettings.resolved().urls)

        // Configuration tier (persisted).
        RelaySettings.configure(urls: "https://relay.idfon.net:8443", token: "tok", relayOnly: true)
        XCTAssertTrue(RelaySettings.isConfigured)
        XCTAssertEqual(RelaySettings.urls, "https://relay.idfon.net:8443")
        XCTAssertEqual(RelaySettings.token, "tok")
        XCTAssertTrue(RelaySettings.isRelayOnly)

        // Parameter tier (per run) wins per field, never persists.
        RelaySettings.configureFromLaunchArgs(["-relayurls", "https://relay.example:8443"])
        XCTAssertEqual(RelaySettings.resolved().urls, "https://relay.example:8443")
        XCTAssertEqual(RelaySettings.resolved().token, "tok") // falls through
        XCTAssertTrue(RelaySettings.resolved().only) // sticky
        XCTAssertEqual(RelaySettings.urls, "https://relay.idfon.net:8443") // unchanged

        // Clearing the parameter restores the persisted tier.
        RelaySettings.configureFromLaunchArgs([])
        XCTAssertEqual(RelaySettings.resolved().urls, "https://relay.idfon.net:8443")

        // No token (allowlist / HTTP-callout relay).
        RelaySettings.configure(urls: "https://relay.example:8443", token: "", relayOnly: false)
        XCTAssertNil(RelaySettings.resolved().token)
        XCTAssertFalse(RelaySettings.resolved().only)

        RelaySettings.clear()
        XCTAssertFalse(RelaySettings.isConfigured)
    }

    func testTicketCookieIsHostOnlyHttpOnlyAndHTTPSOnly() throws {
        EdgeClient.configure(url: "https://idfon.net", ticket: "a,b")
        let secure = try XCTUnwrap(EdgeClient.shared.cookie(
            for: URL(string: "https://acct.idfon.net/fs/a.html")!))
        XCTAssertEqual(secure.name, "__Host-idfon_ticket")
        XCTAssertTrue(secure.isSecure)
        XCTAssertTrue(secure.isHTTPOnly)
        XCTAssertEqual(secure.domain, "acct.idfon.net")
        XCTAssertEqual(secure.value, "a%2Cb", "the ticket is percent-encoded for the cookie value")

        EdgeClient.configure(url: "http://192.168.1.2:8791", ticket: "tok")
        XCTAssertNil(EdgeClient.shared.cookie(
            for: URL(string: "http://192.168.1.2:8791/acct/fs/a.html")!),
            "HTTP edges must not expose requester tickets to page content")
    }

    @MainActor
    func testScopedGatewayCookieIsHiddenFromPageJavaScript() async throws {
        let url = URL(string: "http://localhost:43210/peer/fs/charts/index.html")!
        let cookie = try XCTUnwrap(ArtifactGateway.loopbackCookie(token: "scoped-secret", for: url))
        let visibleCookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "script_visible",
            .value: "yes",
            .domain: "localhost",
            .path: "/peer/fs/charts/",
        ]))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let finished = expectation(description: "HTML page loaded")
        let probe = WebViewLoadProbe(finished: finished)
        webView.navigationDelegate = probe

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        await cookieStore.setCookie(cookie)
        await cookieStore.setCookie(visibleCookie)
        let stored = await cookieStore.allCookies()
        XCTAssertTrue(stored.contains { $0.name == cookie.name && $0.isHTTPOnly })
        webView.loadHTMLString("<!doctype html><title>cookie-check</title>", baseURL: url)
        await fulfillment(of: [finished], timeout: 10)
        let origin = try await webView.evaluateJavaScript("location.origin") as? String
        XCTAssertEqual(origin, "http://localhost:43210")
        let visibleCookies = try await webView.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(visibleCookies?.contains("script_visible=yes") == true)
        XCTAssertFalse(visibleCookies?.contains("scoped-secret") == true,
                       "HttpOnly keeps the scoped credential out of JS")
    }

    @MainActor
    func testSourceSandboxBlocksPeerPortAndRedirectEscapes() async throws {
        let alternatePort = try LoopbackHTTPFixture()
        let page = """
        <!doctype html><title>loading</title><script>
        window.checks = { cookie: document.cookie, allowed: 'pending', peer: 'pending', port: 'pending', encoded: 'pending', redirect: 'pending' };
        Promise.all([
          fetch('/peer/fs/charts/ok.txt').then(r => r.text()).then(v => checks.allowed = v).catch(() => checks.allowed = 'blocked'),
          fetch('/other-peer/fs/charts/secret.txt').then(() => checks.peer = 'loaded').catch(() => checks.peer = 'blocked'),
          fetch('http://localhost:\(alternatePort.port)/peer/fs/charts/alt.txt').then(() => checks.port = 'loaded').catch(() => checks.port = 'blocked'),
          fetch('/peer/fs/charts/%252e%252e/private.txt').then(() => checks.encoded = 'loaded').catch(() => checks.encoded = 'blocked'),
          fetch('/peer/fs/charts/redirect').then(() => checks.redirect = 'loaded').catch(() => checks.redirect = 'blocked')
        ]).then(() => { document.title = 'checks-done'; });
        </script>
        """
        let fixture = try LoopbackHTTPFixture(page: page)
        let url = URL(string: "http://localhost:\(fixture.port)/peer/fs/charts/index.html")!
        let cookie = try XCTUnwrap(ArtifactGateway.loopbackCookie(token: "scoped-secret", for: url))
        let source = GatewayArtifactSource(route: .loopback, url: url, cookie: cookie)
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            fixture.stop()
            alternatePort.stop()
        }
        let webView = SandboxedArtifactWebView(source: source)
        webView.frame = controller.view.bounds
        controller.view.addSubview(webView)

        var checksJSON: String?
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.title") as? String) == "checks-done" {
                checksJSON = try await webView.evaluateJavaScript("JSON.stringify(window.checks)") as? String
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let checks = try XCTUnwrap(checksJSON)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(checks.utf8)) as? [String: String])
        XCTAssertEqual(values["cookie"], "")
        XCTAssertEqual(values["allowed"], "ok")
        XCTAssertEqual(values["peer"], "blocked")
        XCTAssertEqual(values["port"], "blocked")
        XCTAssertEqual(values["encoded"], "blocked")
        XCTAssertEqual(values["redirect"], "blocked")

        let requests = fixture.snapshot()
        XCTAssertTrue(requests.contains { $0.path == "/peer/fs/charts/ok.txt" })
        XCTAssertTrue(requests.contains { $0.path == "/peer/fs/charts/redirect" })
        XCTAssertFalse(requests.contains {
            $0.path.contains("other-peer") || $0.path.contains("redirected") || $0.path.contains("%25")
        })
        XCTAssertTrue(requests.contains {
            $0.path == "/peer/fs/charts/index.html" && $0.cookie?.contains("idfon_gateway=scoped-secret") == true
        })
        XCTAssertTrue(alternatePort.snapshot().isEmpty, "alternate-port request is blocked before network")
    }

    func testSandboxAllowsOnlyExactGatewayOriginAndResourceDirectory() throws {
        let origin = URL(string: "http://localhost:43210/peer/fs/charts/index.html")!
        let cookie = try XCTUnwrap(ArtifactGateway.loopbackCookie(token: "scoped", for: origin))
        XCTAssertEqual(cookie.name, "idfon_gateway")
        XCTAssertEqual(cookie.path, "/peer/fs/charts/")
        XCTAssertTrue(cookie.isHTTPOnly, "page JavaScript cannot read the scoped credential")
        XCTAssertNil(origin.query, "the scoped credential never appears in the page URL")

        let prefix = "/peer/fs/charts/"
        XCTAssertTrue(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://localhost:43210/peer/fs/charts/data.json")!,
            origin: origin, pathPrefix: prefix))
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://localhost:43211/peer/fs/charts/data.json")!,
            origin: origin, pathPrefix: prefix), "alternate ports are different origins")
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://localhost:43210/other-peer/fs/charts/data.json")!,
            origin: origin, pathPrefix: prefix), "another peer path is outside the resource")
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://localhost:43210/peer/fs/charts/%252e%252e/private")!,
            origin: origin, pathPrefix: prefix), "encoded traversal stays outside the resource")
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://localhost:43210/peer/fs/charts//private")!,
            origin: origin, pathPrefix: prefix), "empty path segments are rejected")
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "https://localhost:43210/peer/fs/charts/data.json")!,
            origin: origin, pathPrefix: prefix), "scheme changes are different origins")
        XCTAssertFalse(SandboxedArtifactWebView.allowsGatewayURL(
            URL(string: "http://evil.example/peer/fs/charts/data.json")!,
            origin: origin, pathPrefix: prefix), "foreign origins are blocked")
    }

    func testBackgroundFetchPrunesStaleAndKeepsLegacy() {
        let now = Date()
        let fresh = ["id": "1", "at": "\(now.timeIntervalSince1970)"]
        let stale = ["id": "2", "at": "\(now.timeIntervalSince1970 - 7200)"]
        let legacy = ["id": "3"]
        let kept = BackgroundFetch.pruned([fresh, stale, legacy], now: now, ttl: 3600)
        XCTAssertEqual(kept.map { $0["id"] }, ["1", "3"])
        XCTAssertTrue(BackgroundFetch.isStale(modified: now.addingTimeInterval(-7200), now: now, ttl: 3600))
        XCTAssertFalse(BackgroundFetch.isStale(modified: nil, now: now, ttl: 3600))
    }

    func testAuditRotationKeepsOnePriorFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("action-audit.ndjson")
        try Data(repeating: 0x41, count: 64).write(to: log)
        ActionAudit.rotateIfNeeded(at: log, maxBytes: 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "under the limit is not rotated")
        try Data(repeating: 0x42, count: 2048).write(to: log)
        ActionAudit.rotateIfNeeded(at: log, maxBytes: 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("action-audit.ndjson.1").path))
    }

    func testJSONRenderDropsUnknownComponentsAndCyclesTerminate() throws {
        let json = #"{"root":"r","elements":{"r":{"type":"Row","children":["t","u","r"]},"t":{"type":"Text"},"u":{"type":"Nope"}}}"#
        let spec = try JSONRenderSpec.decode(Data(json.utf8)).normalized()
        XCTAssertNotNil(spec.elements["t"], "known component kept")
        XCTAssertNil(spec.elements["u"], "unknown component dropped with its subtree")
        // The self-edge survives normalization but traversal terminates; the
        // render view's depth limit bounds it.
        XCTAssertEqual(spec.elements["r"]?.children, ["t", "r"], "unknown child id removed")
    }
}
