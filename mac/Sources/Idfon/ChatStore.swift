import Foundation

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
    /// Our endpoint id (public key), for IDFON-RECORDING/1 envelopes.
    private(set) var selfPeerId = "unknown"
    /// Active identity id (cursor keys are per-identity).
    private(set) var identityId = "default"

    /// Fired on the main queue whenever messages/recordingURLs change.
    var onUpdate: (() -> Void)?
    /// Fired with a transient notice for the chat banner.
    var onBanner: ((String) -> Void)?

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
            onUpdate?()
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
        let kind = Self.parseKind(text)
        let message = ChatMessage(id: event.messageId ?? event.eventId, peerId: peerId, kind: kind, outgoing: false, status: nil)
        messages.append(message)
        if case .recording(let ticket, _) = kind {
            onBanner?("Received voice message")
            fetchRecording(ticket: ticket)
        }
        onUpdate?()
    }

    /// Replayed invites older than 60s are from past sessions; never ring.
    private func isStaleInvite(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    /// Parses message text into text vs recording envelope kinds.
    /// Envelope: IDFON-RECORDING/1\nid=..\ncodec=..\nduration_ms=..\nsender_id=..\nticket=..
    static func parseKind(_ text: String) -> MessageKind {
        guard text.hasPrefix("IDFON-RECORDING/1\n") else { return .text(text) }
        var fields: [String: String] = [:]
        for line in text.dropFirst("IDFON-RECORDING/1\n".count).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
        let durationMs = Int(fields["duration_ms"] ?? "") ?? 0
        return .recording(ticket: ticket, durationMs: durationMs)
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
                ChatStore.shared.onUpdate?()
            }
        }
    }

    func appendOutgoing(_ message: ChatMessage) {
        messages.append(message)
        onUpdate?()
    }

    func updateMessage(id: String, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
        onUpdate?()
    }

    func cacheRecording(_ ticket: String, url: URL) {
        recordingURLs[ticket] = url
        onUpdate?()
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