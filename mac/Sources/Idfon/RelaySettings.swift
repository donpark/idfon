import Foundation
import CIdfon

/// Relay selection (docs/relay-config.md): parameter > configuration > default.
///
/// The **configuration** tier is persisted per device (the settings UI writes
/// it). The **parameter** tier is per-run: `-relayurls <url> [-relaytoken
/// <token>] [-relayonly]` at launch overrides the persisted setting for that
/// run only. Out of the box (both tiers empty) the default N0 public relays
/// apply. The resolved selection reaches the Rust core twice: as flags on the
/// spawned `idfond` (`daemonArguments()`) and, for the app's own in-process
/// media endpoints, through the FFI (`applyToProcess()`).
///
/// Runtime config, never compiled in: a relay token baked into an app binary is
/// extractable and cannot be revoked per device. The safe enterprise default is
/// a relay that authorizes endpoint ids (allowlist) or calls an auth service —
/// those need **no** client token at all, so leave `token` empty. Set one only
/// when the relay uses `shared_token`, and prefer provisioning it at runtime.
enum RelaySettings {
    // Configuration tier — persisted per device.
    private static let urlsKey = "idfon.relay.urls"
    private static let tokenKey = "idfon.relay.token"
    private static let onlyKey = "idfon.relay.only"

    /// Parameter tier — the launch-arg override for this run. Never persisted.
    private static var parameter: (urls: String?, token: String?, only: Bool) = (nil, nil, false)

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

    /// The effective selection: parameter over configuration, per field.
    static func resolved() -> (urls: String?, token: String?, only: Bool) {
        (
            parameter.urls ?? urls,
            parameter.token ?? token,
            parameter.only || isRelayOnly
        )
    }

    static var isConfigured: Bool {
        !(resolved().urls?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Launch-arg parameter for automation/tests: `-relayurls <url>
    /// [-relaytoken <token>] [-relayonly]`. Per-run override only — unlike
    /// `configure` it is never persisted, so one launch both sets and uses the
    /// config without pinning it for future runs. Absent fields fall through
    /// to the persisted settings; no relay args at all clear the override.
    static func configureFromLaunchArgs(_ args: [String]) {
        let urls = args.firstIndex(of: "-relayurls").flatMap { index -> String? in
            args.count > index + 1 && !args[index + 1].hasPrefix("-") ? args[index + 1] : nil
        }
        let token = args.firstIndex(of: "-relaytoken").flatMap { index -> String? in
            args.count > index + 1 && !args[index + 1].hasPrefix("-") ? args[index + 1] : nil
        }
        let only = args.contains("-relayonly")
        parameter = (urls, token, only)
        if urls != nil || token != nil || only {
            idfonLog("idfon relay: parameter override urls=\(urls ?? "-") token=\(token == nil ? "none" : "set") only=\(only)")
        }
    }

    /// Persists the configuration tier (the settings UI).
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

    /// Flags for the spawned `idfond` — the CLI-flag parameter channel. Empty
    /// when nothing is configured: the daemon then falls through to its own
    /// sources (`IDFON_RELAY_*`, `~/.idfon/relay.conf`).
    static func daemonArguments() -> [String] {
        let config = resolved()
        var args: [String] = []
        if let urls = config.urls?.trimmingCharacters(in: .whitespacesAndNewlines), !urls.isEmpty {
            args += ["--relay-urls", urls]
        }
        if let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            args += ["--relay-token", token]
        }
        if config.only {
            args.append("--relay-only")
        }
        return args
    }

    /// Environment for a daemon child process: relay auto-enrollment only.
    /// Selection rides on `daemonArguments()`, never on env vars.
    static func enrollEnvironment() -> [String: String] {
        // Relay auto-enrollment (docs/relay-auth.md §6): our deploy runs the
        // auth service on :9443 beside the relay's :8443 (deploy/digitalocean).
        // Derived only for that shape — never probe arbitrary relays — and an
        // explicit env value always wins.
        guard ProcessInfo.processInfo.environment["IDFON_RELAY_ENROLL_URL"] == nil,
              let enroll = enrollUrl(from: resolved().urls ?? "")
        else { return [:] }
        return ["IDFON_RELAY_ENROLL_URL": enroll]
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

    /// Applies the resolved selection to this process's Rust core (the app's
    /// in-process media endpoints bind through it). The FFI setter is the
    /// apps' parameter channel — environment variables are not.
    static func applyToProcess() {
        let config = resolved()
        let urls = config.urls?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        idfon_relay_settings_set(urls, token, config.only)
    }
}
