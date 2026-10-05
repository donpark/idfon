import Foundation

/// A screen that renders live message state. `ChatStore` fans out to every
/// registered observer, so several can be live at once (one peer's thread
/// reachable from more than one tab route).
protocol ChatStoreObserver: AnyObject {
    func chatStoreDidUpdate()
}

/// Message store tailing the daemon event stream.
///
/// The event cursor and rendered messages are persisted so a relaunch (or
/// foreground after suspension) keeps both sides of the conversation visible.
/// The daemon remains the source of truth for incoming-event reconciliation.
final class ChatStore {
    static let shared = ChatStore()
    private static func cursorKey(_ identity: String) -> String { "idfon.event.cursor.\(identity)" }

    private let client = DaemonClient()
    private let queue = DispatchQueue(label: "app.idfon.chatstore")

    private(set) var messages: [ChatMessage] = []
    private var seenMessageIDs = Set<String>()
    private(set) var identityId = "default"

    /// Fired for an invite that needs confirmation (sender not trusted, or the
    /// ticket expired). The UI prompts; on confirm it calls `acceptInvite`.
    var onInvite: ((ContactInvite, String) -> Void)?

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
        get { UserDefaults.standard.string(forKey: Self.cursorKey(identityId)) }
        set { newValue.map { UserDefaults.standard.set($0, forKey: Self.cursorKey(identityId)) } ?? UserDefaults.standard.removeObject(forKey: Self.cursorKey(identityId)) }
    }

    private var started = false
    /// Our endpoint id (public key), for IDFON-RECORDING/1 envelopes.
    private(set) var selfPeerId = "unknown"

    func start() {
        guard !started else { return }
        started = true
        Task {
            if let id = try? await client.identityId() { identityId = id }
            selfPeerId = (try? await client.status())?.1 ?? selfPeerId
            loadMessages()
            await hydrateHistory()
            await runLoop()
        }
    }

    func switchIdentity(to name: String) async throws {
        try await client.useIdentity(name)
        messages = []
        seenMessageIDs.removeAll()
        identityId = (try? await client.identityId()) ?? name
        loadMessages()
        notifyObservers()
    }

    /// Delivers an event (new or replayed) into the store on the main queue.
    private func ingest(_ event: Event) {
        guard !Thread.isMainThread else { ingestOnMain(event); return }
        DispatchQueue.main.async { [weak self] in self?.ingestOnMain(event) }
    }

    private func ingestOnMain(_ event: Event) {
        guard let text = event.messageText, let peerId = event.messagePeerId else { return }
        let messageID = event.messageId ?? event.eventId
        // Daemon message ids are sender-local (an eve holder restarts its
        // counter), so qualify by sender: deduping on the bare id silently
        // dropped a new message that reused an id seen from another sender.
        guard seenMessageIDs.insert("\(peerId)|\(messageID)").inserted else { return }
        // Call-control traffic (live invites, call_started/stopped) routes
        // to the call state machines (each ignores the other's envelopes);
        // never shown as chat history. Invites go through the per-channel
        // incoming-call router (Bar vs CallKit presentation); teardown goes
        // direct to both machines, since the mode governs presentation only.
        // Invites replayed from the event backlog are stale (the call they
        // belonged to already happened) — never ring on them, else every
        // hangup resurrects a ghost call.
        if LiveInvite.parse(text) != nil {
            let stale = isStaleInvite(event)
            idfonLog("idfon live control received peer=\(peerId) message=\(messageID) stale=\(stale)")
            if stale { return }
            DispatchQueue.main.async { Task { @MainActor in
                IncomingCallRouter.shared.route(peerId: peerId, envelope: text)
            } }
            return
        }
        if text == "call_started" || text == "call_stopped" {
            if isStaleControl(event) { return }
            DispatchQueue.main.async { Task { @MainActor in
                LiveCall.shared.handleControl(peer: peerId, text)
                VideoCall.shared.handleEnvelope(peer: peerId, text)
            } }
            return
        }
        // A turn can carry reply text plus one or more trailing envelopes
        // (a transcript followed by an artifact, say). Keep the first part on
        // the event id so replay dedupe and seen-ids still hold.
        let timestamp = Double(event.timestamp).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let (preamble, envelopes) = MessageBody.parse(text)
        var parts: [(String, MessageKind)] = []
        if let preamble { parts.append((preamble, .text(preamble))) }
        for envelope in envelopes {
            // A directory invite becomes a contact, not a raw bubble: enroll the
            // peer and show a short confirmation in its place.
            if let invite = ContactInvite.decode(envelope) {
                // Auto-enroll only from a trusted sender and a live ticket; the
                // message itself is already an Ed25519 sender-signed voucher.
                if !invite.isExpired && AutoEnroll.isTrusted(peerId) {
                    acceptInvite(invite)
                    parts.append(("Added \(invite.name)", .text("Added \(invite.name)")))
                } else {
                    onInvite?(invite, peerId)
                    parts.append(("Contact invite: \(invite.name)", .text("Contact invite: \(invite.name)")))
                }
            } else {
                parts.append((envelope, MessageKind.parse(envelope)))
            }
        }
        if parts.isEmpty { parts.append((text, .text(text))) }
        for (index, part) in parts.enumerated() {
            let partID = index == 0 ? messageID : "\(messageID)#\(index)"
            // Hybrid: with on-device TTS, speak the agent's final transcript.
            if case .callTranscript(let transcript) = part.1, transcript.final {
                Task { @MainActor in
                    HybridVoice.shared.maybeSpeak(peerId: peerId, role: transcript.role, text: transcript.text)
                }
            }
            // Transcript snapshots stream for one turn: upsert the bubble by
            // turn id instead of appending a new one per snapshot.
            if case .callTranscript(let transcript) = part.1,
               let existing = messages.firstIndex(where: {
                   if case .callTranscript(let current) = $0.kind { return current.turnId == transcript.turnId }
                   return false
               }) {
                messages[existing].kind = part.1
                continue
            }
            // A live holder also delivers the agent's reply as a normal
            // message; annotate that bubble in place instead of appending a
            // second copy (the on-device path does this with
            // `recordSpokenTurn(replacing:)`).
            if case .callTranscript(let transcript) = part.1,
               transcript.role == "agent",
               let existing = messages.lastIndex(where: {
                   if case .callTranscript = $0.kind { return false }
                   return $0.peerId == peerId && !$0.outgoing && $0.displayText == transcript.text
               }) {
                messages[existing].kind = part.1
                continue
            }
            if case .file(_, let name, let sizeBytes, _) = part.1 {
                idfonLog("idfon file: received name=\(name) size=\(sizeBytes)")
            }
            messages.append(ChatMessage(id: partID, peerId: peerId, kind: part.1, outgoing: false, timestamp: timestamp, conversation: event.conversationId))
        }
        persistMessages()
        idfonLog("idfon ingested: \(text) from \(peerId), cursor \(event.cursor)")
        notifyObservers()
    }

    /// Accept a directory invite: add the holder as a peer (with the chat
    /// grants) and store the subject-bound capability ticket so sends to it
    /// pass the holder's ingress gate.
    func acceptInvite(_ invite: ContactInvite) {
        Task { [client] in
            do {
                let identity = (try? await client.identityId()) ?? "default"
                try await client.addChannel(name: invite.name, ticketJSON: invite.contactJSON, identity: identity)
                _ = CapabilityTickets.store(invite.ticketJSON, for: invite.endpointId)
                idfonLog("idfon invite: added \(invite.name)")
            } catch {
                idfonError("idfon invite: accept failed \(invite.name): \(error)")
            }
        }
    }

    /// Replayed call controls older than 60s belong to past sessions.
    private func isStaleControl(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    /// Replayed invites older than 60s are from past calls; never ring.
    private func isStaleInvite(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
    }

    func appendOutgoing(_ message: ChatMessage) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.appendOutgoing(message) }
            return
        }
        messages.append(message)
        persistMessages()
        notifyObservers()
    }

    /// Record a voice-call turn as a "spoken" bubble. The client-side cascade
    /// owns the transcript (there is no holder snapshot to ingest); pass
    /// `replacing` to relabel the agent's already-received reply message.
    func recordSpokenTurn(
        peerId: String,
        callId: String,
        turnId: String,
        role: String,
        text: String,
        replacing messageID: String? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.recordSpokenTurn(peerId: peerId, callId: callId, turnId: turnId,
                                       role: role, text: text, replacing: messageID)
            }
            return
        }
        let transcript = CallTranscript(callId: callId, turnId: turnId, role: role, text: text, final: true)
        let kind = MessageKind.callTranscript(transcript)
        if let messageID, let index = messages.firstIndex(where: { $0.peerId == peerId && $0.id == messageID }) {
            messages[index].kind = kind
        } else {
            let id = "spoken-\(turnId)"
            guard !messages.contains(where: { $0.peerId == peerId && $0.id == id }) else { return }
            messages.append(ChatMessage(id: id, peerId: peerId, kind: kind,
                                        outgoing: role != "agent", timestamp: Date()))
        }
        persistMessages()
        notifyObservers()
    }

    private struct StoredMessage: Codable {
        let id: String
        let peerId: String
        let kind: String
        let text: String?
        let ticket: String?
        let name: String?
        let sizeBytes: Int?
        let durationMs: Int?
        let outgoing: Bool
        let timestamp: Date
        let conversation: String?

        init(_ message: ChatMessage) {
            id = message.id; peerId = message.peerId; outgoing = message.outgoing
            timestamp = message.timestamp; conversation = message.conversation
            switch message.kind {
            case .text(let value): kind = "text"; text = value; ticket = nil; name = nil; sizeBytes = nil; durationMs = nil
            case .recording(let value, let duration, _): kind = "recording"; text = nil; ticket = value; name = nil; sizeBytes = nil; durationMs = duration
            case .file(let value, let fileName, let size, _): kind = "file"; text = nil; ticket = value; name = fileName; sizeBytes = size; durationMs = nil
            case .artifact(let artifact):
                kind = "artifact"
                text = ArtifactEnvelope.encodeArtifact(artifact)
                ticket = artifact.blobTicket
                name = artifact.title
                sizeBytes = Int(artifact.sizeBytes)
                durationMs = nil
            case .reference(let reference):
                kind = "reference"
                text = ArtifactEnvelope.encodeReference(reference)
                ticket = nil
                name = nil
                sizeBytes = nil
                durationMs = nil
            case .callTranscript(let transcript):
                kind = "call"
                text = CallEnvelope.encodeCall(transcript)
                ticket = nil
                name = nil
                sizeBytes = nil
                durationMs = nil
            }
        }

        var message: ChatMessage {
            let messageKind: MessageKind
            switch kind {
            case "recording": messageKind = .recording(ticket: ticket ?? "", durationMs: durationMs ?? 0, localURL: nil)
            case "file": messageKind = .file(ticket: ticket ?? "", name: name ?? "file", sizeBytes: sizeBytes ?? 0, localURL: nil)
            case "artifact", "reference", "call": messageKind = MessageKind.parse(text ?? "")
            default: messageKind = .text(text ?? "")
            }
            return ChatMessage(id: id, peerId: peerId, kind: messageKind, outgoing: outgoing, timestamp: timestamp, conversation: conversation)
        }
    }

    /// Session log lives in the app-side session cache (ephemeral by default,
    /// opt-in persistence via `SessionStore.persistLogs`), not UserDefaults.
    private func loadMessages() {
        guard let data = SessionStore.shared.loadSnapshot(identity: identityId),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return }
        // Rebuild with the same per-turn coalescing as live ingest, so streamed
        // transcript snapshots reload as one bubble each.
        var loaded: [ChatMessage] = []
        for entry in stored {
            let message = entry.message
            if case .callTranscript(let transcript) = message.kind,
               let existing = loaded.firstIndex(where: {
                   if case .callTranscript(let current) = $0.kind { return current.turnId == transcript.turnId }
                   return false
               }) {
                loaded[existing].kind = message.kind
                continue
            }
            loaded.append(message)
        }
        messages = loaded
        seenMessageIDs = Set(messages.map { "\($0.peerId)|\($0.id)" })
    }

    private func persistMessages() {
        guard let data = try? JSONEncoder().encode(messages.map(StoredMessage.init)) else { return }
        SessionStore.shared.saveSnapshot(identity: identityId, data: data)
    }

    private static func readKey(_ identity: String, _ id: String) -> String { "idfon.chat.read.\(identity).\(id)" }

    func markRead(_ conversation: Conversation) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.readKey(identityId, conversation.id))
        notifyObservers()
    }

    func unreadCount(for conversation: Conversation) -> Int {
        let readAt = UserDefaults.standard.double(forKey: Self.readKey(identityId, conversation.id))
        return messages(for: conversation).filter { !$0.outgoing && $0.timestamp.timeIntervalSince1970 > readAt }.count
    }

    var recentChatIDs: [String] {
        var latest: [String: Date] = [:]
        for message in messages {
            let id = message.conversation ?? message.peerId
            if latest[id].map({ $0 >= message.timestamp }) == true { continue }
            latest[id] = message.timestamp
        }
        return latest.sorted { $0.value > $1.value }.map(\.key)
    }

    func messages(for peerId: String, conversation: String? = nil) -> [ChatMessage] {
        messages.filter { $0.peerId == peerId && $0.conversation == conversation }
    }

    func messages(for conversation: Conversation) -> [ChatMessage] {
        if let room = conversation.room { return messages(in: room.id) }
        return messages(for: conversation.peer?.id ?? conversation.id)
    }

    func messages(in conversation: String) -> [ChatMessage] {
        messages.filter { $0.conversation == conversation }
    }

    /// Attaches a downloaded file to its message so the cell can offer it
    /// directly instead of re-fetching.
    func attachFile(at url: URL, to messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              case .file(let ticket, let name, let sizeBytes, _) = messages[index].kind else { return }
        messages[index].kind = .file(ticket: ticket, name: name, sizeBytes: sizeBytes, localURL: url)
        persistMessages()
        notifyObservers()
    }

    private func hydrateHistory() async {
        guard let events = try? await client.events(after: nil) else { return }
        for event in events { ingest(event) }
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
                    idfonLog("idfon events: cursor older than retention, restarting from history")
                    cursor = nil // older than retention: restart from retained history
                } else {
                    idfonError("idfon events: wait failed, backing off: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // daemon down: back off
                }
            } catch {
                idfonLog("idfon events: unexpected error: \(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
