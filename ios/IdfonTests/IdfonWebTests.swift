import XCTest

@testable import Idfon

/// App-hosted unit tests for the hybrid web layer
/// (`docs/idfon-web-hybrid-plan.md`): deep-link parsing, edge URL/cookie
/// construction, background-fetch bookkeeping, audit rotation, and json-render
/// normalization. Runs on a device with `xcodebuild test -scheme Idfon`.
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

    func testRelaySettingsRoundTripAndEnvironment() {
        RelaySettings.clear()
        XCTAssertFalse(RelaySettings.isConfigured)
        XCTAssertTrue(RelaySettings.environment().isEmpty)

        RelaySettings.configure(urls: "https://relay.idfon.net:8443", token: "tok", relayOnly: true)
        XCTAssertTrue(RelaySettings.isConfigured)
        XCTAssertEqual(RelaySettings.urls, "https://relay.idfon.net:8443")
        XCTAssertEqual(RelaySettings.token, "tok")
        XCTAssertTrue(RelaySettings.isRelayOnly)
        let env = RelaySettings.environment()
        XCTAssertEqual(env["IDFON_RELAY_URLS"], "https://relay.idfon.net:8443")
        XCTAssertEqual(env["IDFON_RELAY_TOKEN"], "tok")
        XCTAssertEqual(env["IDFON_RELAY_ONLY"], "1")

        // No token (allowlist / HTTP-callout relay): the env omits it.
        RelaySettings.configure(urls: "https://relay.example:8443", token: "", relayOnly: false)
        let plain = RelaySettings.environment()
        XCTAssertNil(plain["IDFON_RELAY_TOKEN"])
        XCTAssertNil(plain["IDFON_RELAY_ONLY"])

        RelaySettings.clear()
        XCTAssertFalse(RelaySettings.isConfigured)
    }

    func testSessionCookieIsSecureOnlyForHTTPS() throws {
        EdgeClient.configure(url: "https://idfon.net", ticket: "a,b")
        let secure = try XCTUnwrap(EdgeClient.shared.sessionCookie)
        XCTAssertTrue(secure.isSecure)
        XCTAssertEqual(secure.domain, "idfon.net")
        XCTAssertEqual(secure.value, "a%2Cb", "the ticket is percent-encoded for the cookie value")

        EdgeClient.configure(url: "http://192.168.1.2:8791", ticket: "tok")
        let plain = try XCTUnwrap(EdgeClient.shared.sessionCookie)
        XCTAssertFalse(plain.isSecure, "a Secure cookie is dropped over plain HTTP")
        XCTAssertEqual(plain.domain, "192.168.1.2")
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
