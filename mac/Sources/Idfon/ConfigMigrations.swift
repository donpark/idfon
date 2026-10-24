import Foundation

/// App-configuration schema migrations: DB-style migrations for UserDefaults
/// config, applied by the app itself at startup.
///
/// Config is written by more than the app — `-edgeurl`/`-edgeticket` launch
/// args, `defaults write`, E2E rig scripts — so stale or test-only config
/// leaks into daily use (2026-10-23: the CallKit E2E rig URL survived
/// teardown and a locked phone never rang). Each build carries the fixes as
/// **one-time steps**: at startup, steps newer than the stored schema version
/// (`idfon.config.version`) run once, in order, and the stored version
/// advances past each. External TestFlight testers get the same self-heal a
/// dev device does — no reinstall, no support session.
///
/// Rules for a new step (mirror of a DB migration):
/// - append at `currentVersion + 1`; never edit or reorder shipped steps;
/// - keep it idempotent — a crash mid-run re-runs it (the version bump is
///   persisted right after each step's writes);
/// - it may only *repair* config, never undo deliberate user/automation
///   config (v1 touches private/loopback edge URLs only).
///
/// Pure core (`migrate`) is host-checkable with plain swiftc: see
/// `ios/Checks/ConfigMigrationsCheck` and `mac/Checks/ConfigMigrationsCheck`.
enum ConfigMigrations {
    /// Canonical config keys (EdgeClient references these — one spelling).
    static let edgeURLKey = "idfon.edge.url"
    static let edgeTicketKey = "idfon.edge.ticket"
    static let versionKey = "idfon.config.version"
    /// The production edge (docs/idfon-edge.md).
    static let productionEdgeURL = "https://idfon.net"

    static let currentVersion = 1

    /// Run pending migrations at startup — before launch-arg config, so
    /// automation wins over a migration, never the other way round.
    static func run() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: versionKey).flatMap(Int.init) ?? 0
        guard stored < currentVersion else { return }
        var config: [String: String] = [:]
        for key in [edgeURLKey, edgeTicketKey] {
            if let value = defaults.string(forKey: key) { config[key] = value }
        }
        for (key, value) in migrate(storedVersion: stored, config: config) {
            defaults.set(value, forKey: key)
        }
        idfonLog("idfon config: schema v\(stored) → v\(currentVersion)")
    }

    /// Pure migration core: the ordered writes to apply — each step's config
    /// fixes followed by the version bump that makes it one-time.
    static func migrate(
        storedVersion: Int, config: [String: String]
    ) -> [(key: String, value: String)] {
        var cfg = config
        var writes: [(key: String, value: String)] = []
        var version = max(0, storedVersion)
        while version < currentVersion {
            version += 1
            for (key, value) in step(version, cfg).sorted(by: { $0.key < $1.key }) {
                cfg[key] = value
                writes.append((key: key, value: value))
            }
            writes.append((key: versionKey, value: String(version)))
        }
        return writes
    }

    private static func step(_ version: Int, _ config: [String: String]) -> [String: String] {
        switch version {
        case 1: return repointTestRigEdge(config)
        default: return [:]
        }
    }

    /// v1 (2026-10-23): the CallKit E2E rig edge URL (`http://<mac-lan-ip>`,
    /// ticket `e2e`) outlived its teardown and ring pushes went nowhere. A
    /// private/loopback edge URL is test residue — repoint it at the
    /// production edge. The ticket is left alone: push routes mint their own
    /// capability tickets per request, so only non-push edge resource routes
    /// see it.
    static func repointTestRigEdge(_ config: [String: String]) -> [String: String] {
        guard let raw = config[edgeURLKey], let host = URL(string: raw)?.host,
              isPrivateHost(host)
        else { return [:] }
        return [edgeURLKey: productionEdgeURL]
    }

    /// RFC1918 / loopback / link-local — the only hosts a local test rig can
    /// live on.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        return parts[0] == 10 || parts[0] == 127
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)
    }
}
