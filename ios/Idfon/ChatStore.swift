import Foundation

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
    /// Fired on the main queue whenever messages change.
    var onUpdate: (() -> Void)?

    private var cursor: String? {
        get { UserDefaults.standard.string(forKey: Self.cursorKey) }
        set { newValue.map { UserDefaults.standard.set($0, forKey: Self.cursorKey) } ?? UserDefaults.standard.removeObject(forKey: Self.cursorKey) }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await runLoop() }
    }

    /// Delivers an event (new or replayed) into the store. Main queue.
    private func ingest(_ event: Event) {
        guard let text = event.messageText, let peerId = event.messagePeerId else { return }
        // Local echo dedupe: our own sends are appended optimistically and
        // come back as incoming events only on the receiving side; the
        // daemon tags events with the sender's peer id, so nothing to skip.
        messages.append(ChatMessage(id: event.messageId ?? event.eventId, peerId: peerId, text: text, outgoing: false))
        NSLog("idfon ingested: \(text) from \(peerId), cursor \(event.cursor)")
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func appendOutgoing(_ message: ChatMessage) {
        messages.append(message)
        DispatchQueue.main.async { self.onUpdate?() }
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
