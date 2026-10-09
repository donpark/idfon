import Foundation

/// Public-edge fetches (`docs/idfon-web-hybrid-plan.md`, P4).
///
/// The edge is an always-on peer that terminates HTTPS and bridges to
/// `idfon/http3/1`, so a resource fetch can keep running in a **background
/// `URLSession`** after iOS suspends the in-process daemon. A direct loopback
/// (P2P) fetch is still preferred while the app is active; the edge is the
/// fallback and the background handoff.
///
/// Config comes from pairing/automation (`-edgeurl` / `-edgeticket`) and lives
/// in `UserDefaults`. The requester credential is an `x-idfon-ticket` value the
/// edge forwards to the resource peer.
final class EdgeClient: NSObject, @unchecked Sendable {
    static let shared = EdgeClient()

    /// Posted after a foreground reconcile; `object` is `[ReconciledArtifact]`.
    static let reconciledNotification = Notification.Name("idfonEdgeReconciled")

    /// A completed background fetch: which resource it is for, and its bytes.
    struct ReconciledArtifact {
        let account: String
        let path: String
        let data: Data
    }

    private static let urlKey = "idfon.edge.url"
    private static let ticketKey = "idfon.edge.ticket"
    private static let pendingKey = "idfon.edge.pending"
    private static let sessionIdentifier = "app.idfon.edge.background"
    /// A background fetch that never completes is abandoned after this, along
    /// with any file it staged.
    private static let pendingTTL: TimeInterval = 60 * 60 * 24

    private var backgroundSession: URLSession?
    private var completionHandler: (() -> Void)?
    private let lock = NSLock()
    /// Set by `runBackgroundHandoffProbe`; gates the diagnostic file log.
    private var probeActive = false

    /// Where completed background downloads are staged until the app
    /// foregrounds and reconciles them.
    static var inbox: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idfon/edge-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var baseURL: URL? {
        UserDefaults.standard.string(forKey: Self.urlKey).flatMap(URL.init(string:))
    }

    var ticket: String? {
        UserDefaults.standard.string(forKey: Self.ticketKey)
    }

    var isConfigured: Bool {
        baseURL != nil && ticket != nil
    }

    /// Persists the edge base URL and requester credential.
    static func configure(url: String, ticket: String) {
        UserDefaults.standard.set(url, forKey: urlKey)
        UserDefaults.standard.set(ticket, forKey: ticketKey)
        idfonLog("idfon edge: configured \(url)")
    }

    /// Removes the configured edge; fetches fall back to direct-only.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: ticketKey)
        idfonLog("idfon edge: cleared")
    }

    /// The edge URL for a resource (the credential rides a cookie/header, never
    /// the URL). `nil` when unconfigured.
    func url(account: String, path: String) -> URL? {
        request(account: account, path: path)?.url
    }

    /// The requester ticket as an `HTTPCookie` scoped to **this resource's
    /// host**, so a `WKWebView` sends it only to that peer. Scoping to the bare
    /// edge domain would send it to every `<ref>.<domain>` (and the path form's
    /// single origin), leaking one endpoint's credential to another.
    /// Percent-encoded: a cookie value cannot carry `,` / `;` / `"` reliably.
    func cookie(for url: URL) -> HTTPCookie? {
        guard let ticket, let host = url.host, !host.isEmpty else { return nil }
        let encoded = ticket.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ticket
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "idfon_ticket",
            .value: encoded,
            .domain: host,
            .path: "/",
        ]
        // Mark Secure only for HTTPS. `HTTPCookie(properties:)` treats the key's
        // presence as Secure regardless of the value, so it must be omitted for
        // a self-hosted/LAN HTTP edge (WebKit drops a Secure cookie over http).
        if url.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    /// The edge URL for `account` with the requester ticket attached.
    ///
    /// A hex endpoint id on an `https://` domain uses the wildcard host form
    /// `<z-base-32>.<domain><path>` (the 64-char hex id does not fit a DNS
    /// label); aliases and IP/localhost bases use `<base>/<account><path>`.
    private func request(account: String, path: String) -> URLRequest? {
        guard let baseURL, let ticket else { return nil }
        let url = Self.resourceURL(baseURL: baseURL, account: account, path: path)
        var request = URLRequest(url: url)
        request.setValue(ticket, forHTTPHeaderField: "x-idfon-ticket")
        request.timeoutInterval = 60
        return request
    }

    static func resourceURL(baseURL: URL, account: String, path: String) -> URL {
        if let host = wildcardHost(baseURL), let short = EndpointRefShort.fromHex(account) {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "\(short).\(host)"
            components.path = path.hasPrefix("/") ? path : "/\(path)"
            if let url = components.url { return url }
        }
        var url = baseURL
        url.appendPathComponent(account)
        // `path` starts with `/`; split so no empty component is appended.
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// The host of an `https://` base that can take a wildcard subdomain, or
    /// `nil` for an IP / `localhost` / explicit-port base.
    private static func wildcardHost(_ baseURL: URL) -> String? {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.port == nil,
              let host = baseURL.host, !host.isEmpty,
              host != "localhost", host.contains(".")
        else { return nil }
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return nil }
        return host
    }

    /// z-base-32 of an endpoint id: 52 chars, the DNS-label-safe form iroh and
    /// pkarr use. The 64-char hex form exceeds the 63-octet DNS label limit.
    enum EndpointRefShort {
        private static let alphabet = Array("ybndrfg8ejkmcpqxot1uwisza345h769")

        /// The 52-char z-base-32 form of a 64-hex endpoint id; `nil` for
        /// anything that is not a hex endpoint id (e.g. an alias).
        static func fromHex(_ hex: String) -> String? {
            guard hex.count == 64, let bytes = bytes(fromHex: hex) else { return nil }
            return encode(bytes)
        }

        static func encode(_ bytes: [UInt8]) -> String {
            var out = ""
            out.reserveCapacity((bytes.count * 8 + 4) / 5)
            var buffer = 0
            var bits = 0
            for byte in bytes {
                buffer = (buffer << 8) | Int(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    out.append(alphabet[(buffer >> bits) & 0x1f])
                }
            }
            if bits > 0 {
                out.append(alphabet[(buffer << (5 - bits)) & 0x1f])
            }
            return out
        }

        private static func bytes(fromHex hex: String) -> [UInt8]? {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
    }

    /// Foreground fetch through the edge. Uses the shared session: the edge
    /// serves a public certificate, so no trust override is needed.
    func fetch(account: String, path: String) async throws -> Data {
        guard let request = request(account: account, path: path) else {
            throw DaemonClient.DaemonError.request("edge is not configured")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw DaemonClient.DaemonError.request("edge returned HTTP \(status)")
        }
        return data
    }

    /// Starts a background download that outlives suspension. The completed
    /// bytes land in `EdgeClient.inbox` for the next foreground reconcile.
    @discardableResult
    func fetchInBackground(account: String, path: String) throws -> Int {
        guard let request = request(account: account, path: path) else {
            throw DaemonClient.DaemonError.request("edge is not configured")
        }
        let task = session().downloadTask(with: request)
        rememberPending(task.taskIdentifier, account: account, path: path)
        task.resume()
        idfonLog("idfon edge: background fetch \(account)\(path) task=\(task.taskIdentifier)")
        return task.taskIdentifier
    }

    /// iOS relaunches the app to deliver background-session events; it hands us
    /// a completion handler that must run once the delegate work is done.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        completionHandler = handler
    }

    /// Recreates the background session so iOS delivers pending download events
    /// to its delegate after a cold-start relaunch. Must be called from
    /// `handleEventsForBackgroundURLSession`, even when no new fetch is started.
    func reconnectBackgroundSession() {
        _ = session()
    }

    var isProbing: Bool { probeActive }

    /// Appends to `Application Support/Idfon/edge-probe.log`, so a suspend or
    /// cold-start handoff can be inspected after the fact (`devicectl --console`
    /// detaches when the app backgrounds). `reset: true` truncates at probe start.
    func probeLog(_ message: String, reset: Bool = false) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idfon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("edge-probe.log")
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        let data = Data(line.utf8)
        if reset {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Device probe for the P4 background handoff (launch arg
    /// `-edgebghandoff <peer> <artifact> [seconds]`): starts a background fetch
    /// without the artifact screen, then drains and logs the reconciled bytes.
    /// `SceneDelegate.sceneWillEnterForeground` drains too, so a real suspend
    /// shows up as the reconcile log after returning.
    func runBackgroundHandoffProbe(peer: String, artifactId: String, delay: TimeInterval) {
        probeActive = true
        probeLog("start configured=\(isConfigured) peer=\(peer) artifact=\(artifactId)", reset: true)
        // Clear leftovers from a previous run so the trace only shows this fetch.
        _ = drainInbox()
        // Print as well as log: `devicectl --console` captures stdout, not os_log.
        func report(_ message: String) {
            idfonLog("idfon edge probe: \(message)")
            print("idfon-edge-probe: \(message)")
            probeLog("probe \(message)")
        }
        NotificationCenter.default.addObserver(
            forName: Self.reconciledNotification, object: nil, queue: .main
        ) { note in
            let records = note.object as? [ReconciledArtifact] ?? []
            report("reconciled \(records.count) record(s) bytes=\(records.first?.data.count ?? 0)")
        }
        do {
            let task = try fetchInBackground(account: peer, path: "/fs/\(artifactId)")
            report("started task=\(task)")
        } catch {
            report("start failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            let records = self?.drainInbox() ?? []
            report("drained \(records.count) record(s) bytes=\(records.first?.data.count ?? 0)")
        }
    }

    /// Drains staged downloads and posts the records (with bytes) so a live
    /// screen can display them. `taskIdentifier → resource` outlives a cold
    /// start via `UserDefaults`.
    @discardableResult
    func drainInbox() -> [ReconciledArtifact] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: Self.inbox, includingPropertiesForKeys: nil) else {
            return []
        }
        var pending = pendingList()
        var reconciled: [ReconciledArtifact] = []
        let now = Date()
        pending = BackgroundFetch.pruned(pending, now: now, ttl: Self.pendingTTL)
        for entry in entries {
            defer { try? manager.removeItem(at: entry) }
            let modified = (try? manager.attributesOfItem(atPath: entry.path)[.modificationDate]) as? Date
            if BackgroundFetch.isStale(modified: modified, now: now, ttl: Self.pendingTTL) {
                continue
            }
            let id = entry.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: entry), !data.isEmpty,
                  let index = pending.firstIndex(where: { $0["id"] == id }),
                  let account = pending[index]["account"],
                  let path = pending[index]["path"] else { continue }
            reconciled.append(ReconciledArtifact(account: account, path: path, data: data))
            pending.remove(at: index)
        }
        setPending(pending)
        if probeActive { probeLog("drain \(reconciled.count) record(s)") }
        if !reconciled.isEmpty {
            idfonLog("idfon edge: reconciled \(reconciled.count) background fetch(es)")
            NotificationCenter.default.post(name: Self.reconciledNotification, object: reconciled)
        }
        return reconciled
    }

    private func pendingList() -> [[String: String]] {
        UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: String]] ?? []
    }

    private func setPending(_ list: [[String: String]]) {
        UserDefaults.standard.set(list, forKey: Self.pendingKey)
    }

    private func rememberPending(_ id: Int, account: String, path: String) {
        var pending = pendingList()
        pending.append([
            "id": "\(id)",
            "account": account,
            "path": path,
            "at": "\(Date().timeIntervalSince1970)",
        ])
        setPending(pending)
    }

    private func removePending(_ id: Int) {
        setPending(pendingList().filter { $0["id"] != "\(id)" })
    }

    private func session() -> URLSession {
        if let backgroundSession { return backgroundSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        backgroundSession = session
        return session
    }
}

extension EdgeClient: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A download task delivers the body even for a 4xx/5xx; without this
        // check an error page would be staged and rendered as the artifact.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        if probeActive { probeLog("delegate task=\(downloadTask.taskIdentifier) status=\(status)") }
        guard status == 200 else {
            idfonLog("idfon edge: background fetch \(downloadTask.taskIdentifier) HTTP \(status), not staged")
            removePending(downloadTask.taskIdentifier)
            return
        }
        let destination = Self.inbox.appendingPathComponent("\(downloadTask.taskIdentifier).bin")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            idfonLog("idfon edge: background fetch \(downloadTask.taskIdentifier) staged")
        } catch {
            idfonLog("idfon edge: stage failed: \(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.completionHandler?()
            self?.completionHandler = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        idfonLog("idfon edge: background fetch \(task.taskIdentifier) failed: \(error?.localizedDescription ?? "")")
        removePending(task.taskIdentifier)
    }
}
