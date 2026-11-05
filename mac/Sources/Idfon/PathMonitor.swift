import AppKit
import CIdfon
import Network

/// OS-level network-path transitions (`docs/media-adaptation.md` §C9, #86).
///
/// The Mac's transitions are Wi-Fi↔Ethernet, VPN up/down and sleep/wake; iOS
/// learned the same lesson on a drive (2026-11-04): the tag is what lines a
/// call record up with the network it ran on. Logging only — the pre-grow /
/// pre-step half of #86 waits for the profile layer. Cheap for the process
/// lifetime.
enum PathMonitor {
    private static let monitor = NWPathMonitor()
    /// One serial queue owns the handler, so `last` needs no lock.
    private static let queue = DispatchQueue(label: "idfon.pathmonitor")
    private static var last: String?

    static func start() {
        monitor.pathUpdateHandler = { path in
            let line = describe(path)
            guard line != last else { return }
            last = line
            idfonLog("idfon net path: \(line)")
            Diag.log("netpath", ["path": line])
            // Let the media plane catch a stall as it happens: it shortens the
            // subscribe watchdog for a grace window.
            media_live_path_changed()
        }
        monitor.start(queue: queue)
    }

    private static func describe(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires"
        @unknown default: status = "unknown"
        }
        var kinds: [String] = []
        if path.usesInterfaceType(.wifi) { kinds.append("wifi") }
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("wired") }
        if path.usesInterfaceType(.cellular) { kinds.append("cellular") }
        if path.usesInterfaceType(.loopback) { kinds.append("loopback") }
        if path.usesInterfaceType(.other) { kinds.append("other") }
        return "\(status) \(kinds.isEmpty ? "none" : kinds.joined(separator: "+"))"
            + " expensive=\(path.isExpensive ? 1 : 0)"
            + " constrained=\(path.isConstrained ? 1 : 0)"
    }
}
