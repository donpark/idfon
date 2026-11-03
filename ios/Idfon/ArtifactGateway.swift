import Foundation

/// A gateway URL for one artifact: the identity's **loopback** gateway (which
/// itself fetches direct, with the daemon's edge fallback) or the **public
/// edge** directly when no local daemon answers.
///
/// A `WKWebView` cannot set request headers, so loopback and edge credentials
/// ride in HttpOnly cookies. See
/// `docs/idfon-edge.md` (P2/P4).
struct GatewayArtifactSource {
    enum Route {
        case loopback
        case edge
    }

    let route: Route
    let url: URL
    /// Scoped HttpOnly credential carried by this WebView.
    let cookie: HTTPCookie
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
        var resource = URLComponents()
        resource.path = path
        let scopedPath = resource.percentEncodedPath
        guard let gateway = try? await IdfonClient().gatewayStart(account: account, path: scopedPath),
              let port = URLComponents(string: "http://\(gateway.addr)")?.port else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = port
        components.path = "/\(account)\(path)"
        guard let url = components.url,
              let cookie = loopbackCookie(token: gateway.token, for: url) else { return nil }
        return GatewayArtifactSource(route: .loopback, url: url, cookie: cookie)
    }

    static func loopbackCookie(token: String, for url: URL) -> HTTPCookie? {
        guard url.scheme == "http", url.host == "localhost", !token.isEmpty else { return nil }
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return HTTPCookie(properties: [
            .name: "idfon_gateway",
            .value: token,
            .domain: "localhost",
            .path: resourcePathPrefix(encodedPath),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ])
    }

    private static func resourcePathPrefix(_ path: String) -> String {
        if path.hasSuffix("/") { return path }
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[...slash])
    }

    private static func remote(account: String, path: String) -> GatewayArtifactSource? {
        guard let url = EdgeClient.shared.url(account: account, path: path),
              let cookie = EdgeClient.shared.cookie(for: url) else { return nil }
        return GatewayArtifactSource(route: .edge, url: url, cookie: cookie)
    }
}
