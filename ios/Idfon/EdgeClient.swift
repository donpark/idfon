import Foundation
import UIKit

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

    private var backgroundSession: URLSession?
    private var completionHandler: (() -> Void)?
    private let lock = NSLock()

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

    /// The edge URL for a resource (the credential rides a cookie/header, never
    /// the URL). `nil` when unconfigured.
    func url(account: String, path: String) -> URL? {
        request(account: account, path: path)?.url
    }

    /// The requester ticket as an `HTTPCookie` for the edge domain, so a
    /// `WKWebView` sends it on every request to the edge (subresources included).
    /// Percent-encoded: a cookie value cannot carry `,` / `;` / `"` reliably.
    var sessionCookie: HTTPCookie? {
        guard let baseURL, let host = baseURL.host, let ticket else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let encoded = ticket.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ticket
        return HTTPCookie(properties: [
            .name: "idfon_ticket",
            .value: encoded,
            .domain: "\(domain)",
            .path: "/",
            .secure: true,
        ])
    }

    /// `https://<base>/<account><path>` with the requester ticket attached.
    private func request(account: String, path: String) -> URLRequest? {
        guard let baseURL, let ticket else { return nil }
        var url = baseURL
        url.appendPathComponent(account)
        // `path` starts with `/`; split so no empty component is appended.
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.setValue(ticket, forHTTPHeaderField: "x-idfon-ticket")
        request.timeoutInterval = 60
        return request
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
        for entry in entries {
            defer { try? manager.removeItem(at: entry) }
            let id = entry.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: entry), !data.isEmpty,
                  let index = pending.firstIndex(where: { $0["id"] == id }),
                  let account = pending[index]["account"],
                  let path = pending[index]["path"] else { continue }
            reconciled.append(ReconciledArtifact(account: account, path: path, data: data))
            pending.remove(at: index)
        }
        setPending(pending)
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
        pending.append(["id": "\(id)", "account": account, "path": path])
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
