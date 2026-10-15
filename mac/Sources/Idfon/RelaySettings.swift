import Foundation

/// Enterprise relay configuration, persisted per device and applied to the
/// daemon when it starts (`IDFON_RELAY_URLS` / `IDFON_RELAY_TOKEN` /
/// `IDFON_RELAY_ONLY`).
///
/// Runtime config, never compiled in: a relay token baked into an app binary is
/// extractable and cannot be revoked per device. The safe enterprise default is
/// a relay that authorizes endpoint ids (allowlist) or calls an auth service —
/// those need **no** client token at all, so leave `token` empty. Set one only
/// when the relay uses `shared_token`, and prefer provisioning it at runtime.
enum RelaySettings {
    private static let urlsKey = "idfon.relay.urls"
    private static let tokenKey = "idfon.relay.token"
    private static let onlyKey = "idfon.relay.only"

    /// Comma-separated relay URLs (`https://relay.example:8443`).
    static var urls: String? {
        UserDefaults.standard.string(forKey: urlsKey)
    }

    /// Optional shared bearer token (empty for allowlist / HTTP-callout relays).
    static var token: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    /// Drop IP transports (relay-only). Mainly a test/enterprise debugging flag.
    static var isRelayOnly: Bool {
        UserDefaults.standard.bool(forKey: onlyKey)
    }

    static var isConfigured: Bool {
        !(urls?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static func configure(urls: String, token: String, relayOnly: Bool = false) {
        let urls = urls.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(urls, forKey: urlsKey)
        UserDefaults.standard.set(token.isEmpty ? nil : token, forKey: tokenKey)
        UserDefaults.standard.set(relayOnly, forKey: onlyKey)
        idfonLog("idfon relay: configured urls=\(urls.isEmpty ? "-" : urls) token=\(token.isEmpty ? "none" : "set") only=\(relayOnly)")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: urlsKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: onlyKey)
        idfonLog("idfon relay: cleared")
    }

    /// Environment for a daemon child process (macOS subprocess).
    static func environment() -> [String: String] {
        guard let urls, !urls.isEmpty else { return [:] }
        var env = ["IDFON_RELAY_URLS": urls]
        if let token, !token.isEmpty { env["IDFON_RELAY_TOKEN"] = token }
        if isRelayOnly { env["IDFON_RELAY_ONLY"] = "1" }
        // Relay auto-enrollment (docs/relay-auth.md §6): our deploy runs the
        // auth service on :9443 beside the relay's :8443 (deploy/digitalocean).
        // Derived only for that shape — never probe arbitrary relays — and an
        // explicit env value always wins.
        if ProcessInfo.processInfo.environment["IDFON_RELAY_ENROLL_URL"] == nil,
           let enroll = Self.enrollUrl(from: urls) {
            env["IDFON_RELAY_ENROLL_URL"] = enroll
        }
        return env
    }

    private static func enrollUrl(from urls: String) -> String? {
        for value in urls.split(separator: ",") {
            guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
                  components.port == 8443, components.host != nil else { continue }
            components.port = 9443
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.string
        }
        return nil
    }

    /// Sets the variables in this process (iOS runs the daemon in-process).
    static func applyToProcess() {
        for (key, value) in environment() {
            setenv(key, value, 1)
        }
    }
}
