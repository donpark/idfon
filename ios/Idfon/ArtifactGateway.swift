import Foundation

/// A gateway URL for one artifact: the identity's **loopback** gateway (which
/// itself fetches direct, with the daemon's edge fallback) or the **public
/// edge** directly when no local daemon answers.
///
/// A `WKWebView` cannot set request headers, so the loopback bearer token rides
/// as `?token=` and the edge requester ticket as a cookie. See
/// `docs/idfon-web-hybrid-plan.md` (P2/P4).
struct GatewayArtifactSource {
    enum Route {
        case loopback
        case edge
    }

    let route: Route
    let url: URL
    /// Set for the edge route; `nil` for loopback (token is in the URL).
    let cookie: HTTPCookie?
    /// The only host the web view is allowed to load from.
    let host: String
}

enum ArtifactGateway {
    /// Prefers the loopback gateway (the daemon routes direct → edge); falls
    /// back to the public edge when no local daemon answers.
    static func source(account: String, path: String) async -> GatewayArtifactSource? {
        if let source = await loopback(account: account, path: path) {
            return source
        }
        return remote(account: account, path: path)
    }

    private static func loopback(account: String, path: String) async -> GatewayArtifactSource? {
        guard let gateway = try? await DaemonClient().gatewayStart(),
              var components = URLComponents(string: "http://\(gateway.addr)/\(account)\(path)") else {
            return nil
        }
        // The gateway accepts the bearer token as `?token=` on top of the
        // `Authorization` header, which a web view cannot set.
        components.queryItems = [URLQueryItem(name: "token", value: gateway.token)]
        guard let url = components.url else { return nil }
        return GatewayArtifactSource(route: .loopback, url: url, cookie: nil, host: "127.0.0.1")
    }

    private static func remote(account: String, path: String) -> GatewayArtifactSource? {
        guard let url = EdgeClient.shared.url(account: account, path: path) else { return nil }
        return GatewayArtifactSource(
            route: .edge,
            url: url,
            cookie: EdgeClient.shared.sessionCookie,
            host: url.host ?? "")
    }
}
