import Foundation

/// A screen that renders live message state. `ChatStore` fans out to every
/// registered observer, so several can be live at once (one peer's thread
/// reachable from more than one tab route).
protocol ChatStoreObserver: AnyObject {
    func chatStoreDidUpdate()
}

/// In-memory message store tailing the daemon event stream.
///
/// The event cursor is persisted so a relaunch (or foreground after
/// suspension) replays everything since the last seen event — the shared
/// reconciliation pattern from docs/native-shells-plan.md. Message bodies
/// are memory-only for M2; events after the persisted cursor are
/// re-delivered, so nothing sent while the app was dead is lost.
final class ChatStore {
    static let shared = ChatStore()
    static let cursorKey = "idfon.event.cursor"

    private let client = DaemonClient()
    private let queue = DispatchQueue(label: "app.idfon.chatstore")

    private(set) var messages: [ChatMessage] = []

    /// Registered screens, held weakly so a deallocated one drops out without
    /// an explicit unregister. Touched on the main queue only.
    private let observers = NSHashTable<AnyObject>.weakObjects()

    func addObserver(_ observer: ChatStoreObserver) {
        observers.add(observer)
    }

    private func notifyObservers() {
        for case let observer as ChatStoreObserver in observers.allObjects {
            observer.chatStoreDidUpdate()
        }
    }

    private var cursor: String? {
        get { UserDefaults.standard.string(forKey: Self.cursorKey) }
        set { newValue.map { UserDefaults.standard.set($0, forKey: Self.cursorKey) } ?? UserDefaults.standard.removeObject(forKey: Self.cursorKey) }
    }

    private var started = false
    /// Our endpoint id (public key), for IDFON-RECORDING/1 envelopes.
    private(set) var selfPeerId = "unknown"

    func start() {
        guard !started else { return }
        started = true
        Task { await runLoop() }
        Task { selfPeerId = (try? await client.status())?.1 ?? selfPeerId }
    }

    /// Delivers an event (new or replayed) into the store. Main queue.
    private func ingest(_ event: Event) {
        guard let text = event.messageText, let peerId = event.messagePeerId else { return }
        // Call-control traffic (live invites, call_started/stopped) routes
        // to the call state machines (each ignores the other's envelopes);
        // never shown as chat history. Invites go through the per-connection
        // incoming-call router (Bar vs CallKit presentation); teardown goes
        // direct to both machines, since the mode governs presentation only.
        // Invites replayed from the event backlog are stale (the call they
        // belonged to already happened) — never ring on them, else every
        // hangup resurrects a ghost call.
        if LiveInvite.parse(text) != nil {
            if isStaleInvite(event) { return }
            DispatchQueue.main.async { Task { @MainActor in
                IncomingCallRouter.shared.route(peerId: peerId, envelope: text)
            } }
            return
        }
        if text == "call_started" || text == "call_stopped" {
            DispatchQueue.main.async { Task { @MainActor in
                LiveCall.shared.handleControl(peer: peerId, text)
                VideoCall.shared.handleEnvelope(peer: peerId, text)
            } }
            return
        }
        let kind = MessageKind.parse(text)
        if case .file(_, let name, let sizeBytes, _) = kind {
            NSLog("idfon file: received name=\(name) size=\(sizeBytes)")
        }
        let timestamp = Double(event.timestamp).map(Date.init(timeIntervalSince1970:)) ?? Date()
        messages.append(ChatMessage(id: event.messageId ?? event.eventId, peerId: peerId, kind: kind, outgoing: false, timestamp: timestamp))
        NSLog("idfon ingested: \(text) from \(peerId), cursor \(event.cursor)")
        DispatchQueue.main.async { self.notifyObservers() }
    }

    /// Replayed invites older than 60s are from past calls; never ring.
    private func isStaleInvite(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    func appendOutgoing(_ message: ChatMessage) {
        messages.append(message)
        DispatchQueue.main.async { self.notifyObservers() }
    }

    /// Attaches a downloaded file to its message so the cell can offer it
    /// directly instead of re-fetching.
    func attachFile(at url: URL, to messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              case .file(let ticket, let name, let sizeBytes, _) = messages[index].kind else { return }
        messages[index].kind = .file(ticket: ticket, name: name, sizeBytes: sizeBytes, localURL: url)
        DispatchQueue.main.async { self.notifyObservers() }
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
                    NSLog("idfon events: cursor older than retention, restarting from history")
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
