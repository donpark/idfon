// Source-load security check for the macOS WKWebView. This compiles the
// production sandbox, then checks that its live WebKit content rules block
// peer-path, alternate-port, encoded-traversal, and redirect escapes.
//
//   swiftc -parse-as-library -framework AppKit -framework Network -framework WebKit \
//     -o /tmp/idfon-webview-source-check \
//     mac/Sources/Idfon/SandboxedArtifactWebView.swift \
//     mac/Checks/ArtifactWebViewSourceCheck/main.swift
//   /tmp/idfon-webview-source-check

import AppKit
import Foundation
import Network
import WebKit

enum ArtifactSelector: Codable {
    case text(start: UInt64, end: UInt64, quote: String?)
}

struct GatewayArtifactSource {
    enum Route { case loopback }
    let route: Route
    let url: URL
    let cookie: HTTPCookie
}

private final class LoopbackHTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let cookie: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "idfon.mac-web-test-http")
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
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
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
        let parts = lines.first?.split(separator: " ") ?? []
        let path = parts.count > 1 ? String(parts[1]) : "/"
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
        let type = path.hasSuffix(".html") ? "text/html" : "text/plain"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor
@main
struct ArtifactWebViewSourceCheck {
    static func main() async throws {
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
        let cookie = HTTPCookie(properties: [
            .name: "idfon_gateway",
            .value: "scoped-secret",
            .domain: "localhost",
            .path: "/peer/fs/charts/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ])!
        let webView = SandboxedArtifactWebView(
            source: GatewayArtifactSource(route: .loopback, url: url, cookie: cookie))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        webView.frame = window.contentView?.bounds ?? .zero
        window.orderFrontRegardless()
        defer {
            window.close()
            fixture.stop()
            alternatePort.stop()
        }

        var checksJSON: String?
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.title") as? String) == "checks-done" {
                checksJSON = try await webView.evaluateJavaScript("JSON.stringify(window.checks)") as? String
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let checksJSON,
              let checks = try JSONSerialization.jsonObject(with: Data(checksJSON.utf8)) as? [String: String] else {
            throw NSError(domain: "ArtifactWebViewSourceCheck", code: 2)
        }
        precondition(checks["cookie"] == "", "page JavaScript read the HttpOnly cookie")
        precondition(checks["allowed"] == "ok", "same-directory subresource was blocked")
        precondition(checks["peer"] == "blocked", "another peer path loaded")
        precondition(checks["port"] == "blocked", "alternate port was reachable")
        precondition(checks["encoded"] == "blocked", "encoded traversal path loaded")
        precondition(checks["redirect"] == "blocked", "off-scope redirect loaded")
        let requests = fixture.snapshot()
        precondition(requests.contains { $0.path == "/peer/fs/charts/ok.txt" })
        precondition(requests.contains { $0.path == "/peer/fs/charts/redirect" })
        precondition(!requests.contains { $0.path.contains("other-peer") || $0.path.contains("private.txt") || $0.path.contains("redirected") })
        precondition(requests.contains {
            $0.path == "/peer/fs/charts/index.html" && $0.cookie?.contains("idfon_gateway=scoped-secret") == true
        })
        precondition(alternatePort.snapshot().isEmpty, "alternate-port request reached the listener")
        print("PASS: macOS source-loaded WebView origin, credential, and path boundaries")
    }
}
