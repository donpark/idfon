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
        // to the video-call state machine; never shown as chat history.
        // Invites replayed from the event backlog are stale (the call they
        // belonged to already happened) — never ring on them, else every
        // hangup resurrects a ghost call.
        if LiveInvite.parse(text) != nil {
            if isStaleInvite(event) { return }
            DispatchQueue.main.async { Task { @MainActor in VideoCall.shared.handleEnvelope(peer: peerId, text) } }
            return
        }
        if text == "call_started" || text == "call_stopped" {
            DispatchQueue.main.async { Task { @MainActor in VideoCall.shared.handleEnvelope(peer: peerId, text) } }
            return
        }
        let kind = Self.parseKind(text)
        messages.append(ChatMessage(id: event.messageId ?? event.eventId, peerId: peerId, kind: kind, outgoing: false))
        NSLog("idfon ingested: \(text) from \(peerId), cursor \(event.cursor)")
        DispatchQueue.main.async { self.onUpdate?() }
    }

    /// Replayed invites older than 60s are from past calls; never ring.
    private func isStaleInvite(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    /// Parses message text into text vs recording envelope kinds.
    /// Envelope: IDFON-RECORDING/1\nid=..\ncodec=..\nsample_rate=..\nduration_ms=..\nsender_id=..\nticket=..
    static func parseKind(_ text: String) -> MessageKind {
        guard text.hasPrefix("IDFON-RECORDING/1\n") else { return .text(text) }
        var fields: [String: String] = [:]
        for line in text.dropFirst("IDFON-RECORDING/1\n".count).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
        let durationMs = Int(fields["duration_ms"] ?? "") ?? 0
        return .recording(ticket: ticket, durationMs: durationMs, localURL: nil)
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
