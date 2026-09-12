import Foundation

/// A screen that renders live message state. `ChatStore` fans out to every
/// registered observer, so more than one chat can be live at once.
@MainActor
protocol ChatStoreObserver: AnyObject {
    func chatStoreDidUpdate()
}

/// In-memory message store tailing the daemon event stream.
///
/// The event cursor is persisted per identity so a relaunch replays
/// everything since the last seen event. Message bodies are memory-only;
/// recording blobs are fetched to disk so they play back.
@MainActor
final class ChatStore {
    static let shared = ChatStore()

    let client = DaemonClient()

    private(set) var messages: [ChatMessage] = []
    /// Local playback files for recording tickets (tmp; populated by the
    /// eager fetch on ingest).
    private(set) var recordingURLs: [String: URL] = [:]
    /// Local copies of received files (saved to ~/Downloads on ingest).
    private(set) var fileURLs: [String: URL] = [:]
    /// Our endpoint id (public key), for IDFON-RECORDING/1 envelopes.
    private(set) var selfPeerId = "unknown"
    /// Active identity id (cursor keys are per-identity).
    private(set) var identityId = "default"

    /// Registered screens, held weakly so a deallocated one drops out without
    /// an explicit unregister. Main-actor isolated, like the store.
    private let observers = NSHashTable<AnyObject>.weakObjects()

    /// Fired with a transient notice for the chat banner.
    var onBanner: ((String) -> Void)?

    func addObserver(_ observer: ChatStoreObserver) {
        observers.add(observer)
    }

    private func notifyObservers() {
        for case let observer as ChatStoreObserver in observers.allObjects {
            observer.chatStoreDidUpdate()
        }
    }

    private var cursor: String? {
        get { UserDefaults.standard.string(forKey: Self.cursorKey(identityId)) }
        set { newValue.map { UserDefaults.standard.set($0, forKey: Self.cursorKey(identityId)) } ?? UserDefaults.standard.removeObject(forKey: Self.cursorKey(identityId)) }
    }

    private static func cursorKey(_ identity: String) -> String { "idfon.event.cursor.\(identity)" }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await runLoop() }
        Task {
            if let id = try? await client.identityId() {
                identityId = id
            }
        }
    }

    /// Switches identity (after identity.use): resets history and cursors —
    /// events are per-identity. The run loop keeps polling; the daemon now
    /// serves the new active identity.
    func switchIdentity(to name: String) {
        messages = []
        recordingURLs = [:]
        fileURLs = [:]
        Task {
            do {
                let raw = try await client.request(method: "identity.use", params: ["name": AnyEncodable(name)])
                identityId = raw?["identity"]?["id"]?.stringValue ?? name
                if let status = try? await client.status(), status.ready {
                    selfPeerId = status.identityName
                }
                if let id = try? await client.identityId() { identityId = id }
                onBanner?("Switched to \(name)")
            } catch {
                onBanner?("Identity switch failed: \(error.localizedDescription)")
            }
            notifyObservers()
        }
    }

    /// Delivers an event (new or replayed) into the store.
    private func ingest(_ event: Event) {
        guard let text = event.messageText, let peerId = event.messagePeerId else { return }
        // Call-control traffic (live invites, call_started/stopped) routes
        // to the call state machines; never shown as chat history. Invites
        // replayed after a relaunch are stale (app was closed when they
        // arrived) — ring only fresh ones, matching the GUI's drain logic.
        if LiveInvite.parse(text) != nil {
            if isStaleInvite(event) { return }
            LiveCall.shared.handleEnvelope(peer: peerId, text)
            VideoCall.shared.handleEnvelope(peer: peerId, text)
            return
        }
        if text == "call_started" || text == "call_stopped" {
            LiveCall.shared.handleControl(peer: peerId, text)
            VideoCall.shared.handleEnvelope(peer: peerId, text)
            return
        }
        let kind = MessageKind.parse(text)
        let timestamp = Double(event.timestamp).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let message = ChatMessage(id: event.messageId ?? event.eventId, peerId: peerId, kind: kind, outgoing: false, status: nil, timestamp: timestamp)
        messages.append(message)
        if case .recording(let ticket, _) = kind {
            onBanner?("Received voice message")
            fetchRecording(ticket: ticket)
        }
        if case .file(let ticket, let name, let sizeBytes) = kind {
            onBanner?("Received file")
            fetchFile(ticket: ticket, name: name, sizeBytes: sizeBytes)
        }
        notifyObservers()
    }

    /// Replayed invites older than 60s are from past sessions; never ring.
    private func isStaleInvite(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    /// Fetches a recording blob to a tmp file so it can be played.
    private func fetchRecording(ticket: String) {
        Task.detached(priority: .userInitiated) { [client] in
            guard let data = try? await client.fetchBlob(ticket), !data.isEmpty else {
                NSLog("idfon: recording fetch failed \(ticket.prefix(16))...")
                await MainActor.run { ChatStore.shared.onBanner?("Could not receive recording") }
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(ticket.replacingOccurrences(of: "/", with: "_"))
            try? data.write(to: url)
            await MainActor.run {
                ChatStore.shared.recordingURLs[ticket] = url
                ChatStore.shared.notifyObservers()
            }
        }
    }

    func appendOutgoing(_ message: ChatMessage) {
        messages.append(message)
        notifyObservers()
    }

    func updateMessage(id: String, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
        notifyObservers()
    }

    func cacheRecording(_ ticket: String, url: URL) {
        recordingURLs[ticket] = url
        notifyObservers()
    }

    /// Fetches a received file straight to ~/Downloads, so §5's "saved to the
    /// recipient's device" holds without the user having to ask.
    private func fetchFile(ticket: String, name: String, sizeBytes: Int) {
        Task.detached(priority: .userInitiated) { [client] in
            guard let data = try? await client.fetchBlob(ticket), !data.isEmpty else {
                await MainActor.run { ChatStore.shared.onBanner?("Could not receive file") }
                return
            }
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            // The sender's name is untrusted: never let it escape Downloads.
            let safe = (name as NSString).lastPathComponent
            var url = dir.appendingPathComponent(safe)
            if FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safe)")
            }
            let saved = url
            do {
                try data.write(to: saved)
            } catch {
                await MainActor.run { ChatStore.shared.onBanner?("Could not save file") }
                return
            }
            await MainActor.run {
                ChatStore.shared.fileURLs[ticket] = saved
                ChatStore.shared.notifyObservers()
            }
            NSLog("idfon file: received name=\(safe) size=\(sizeBytes)")
        }
    }

    func cacheFile(_ ticket: String, url: URL) {
        fileURLs[ticket] = url
        notifyObservers()
    }

    /// Peer ids ordered by most recent message (newest first) — feeds the
    /// sidebar's Recents section. Session-only: message bodies are memory-only.
    var recentPeerIds: [String] {
        var latest: [String: Date] = [:]
        for message in messages {
            if let current = latest[message.peerId], current >= message.timestamp { continue }
            latest[message.peerId] = message.timestamp
        }
        return latest.sorted { $0.value > $1.value }.map(\.key)
    }

    private func runLoop() async {
        while true {
            do {
                let events = try await client.waitMessages(after: cursor)
                if events.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // idle breathing room
                }
                for event in events {
                    cursor = event.cursor
                    ingest(event)
                }
            } catch let error as DaemonClient.DaemonError {
                if let message = error.errorDescription, message.contains("cursor") {
                    cursor = nil // older than retention: restart from retained history
                } else {
                    NSLog("idfon events: wait failed, backing off: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // daemon down: back off
                }
            } catch {
                NSLog("idfon events: unexpected error: \(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}