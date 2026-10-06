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
    private var seenMessageIDs = Set<String>()
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

    /// Fired for an invite that needs a confirmation (sender not trusted, or
    /// ticket expired). The UI prompts; on confirm it calls `acceptInvite`.
    var onInvite: ((ContactInvite, String) -> Void)?
    /// Fired when an agent points at part of an artifact (`IDFON-POINT/1`). The
    /// UI opens the artifact with the highlight; no chat bubble is added.
    var onPoint: ((PointEnvelope, String) -> Void)?
    /// Fired when an agent asks the app to open an artifact (`IDFON-SHOW/1`).
    var onShow: ((ShowEnvelope, String) -> Void)?
    /// Fired when an agent requests a screenshot (`IDFON-SCREENSHOT/1`).
    var onScreenshot: ((ScreenshotEnvelope, String) -> Void)?
    /// Points/shows that arrived with no chat on screen, drained when one appears.
    private var pendingPoints: [String: [PointEnvelope]] = [:]
    private var pendingShows: [String: [ShowEnvelope]] = [:]
    private var pendingScreenshots: [String: [ScreenshotEnvelope]] = [:]

    func takePendingPoints(peerId: String) -> [PointEnvelope] {
        let points = pendingPoints[peerId] ?? []
        pendingPoints[peerId] = nil
        return points
    }

    func takePendingShows(peerId: String) -> [ShowEnvelope] {
        let shows = pendingShows[peerId] ?? []
        pendingShows[peerId] = nil
        return shows
    }

    func takePendingScreenshots(peerId: String) -> [ScreenshotEnvelope] {
        let requests = pendingScreenshots[peerId] ?? []
        pendingScreenshots[peerId] = nil
        return requests
    }

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
        Task {
            if let id = try? await client.identityId() { identityId = id }
            await hydrateHistory()
            await runLoop()
        }
    }

    /// Switches identity (after identity.use): resets history and cursors —
    /// events are per-identity. The run loop keeps polling; the daemon now
    /// serves the new active identity.
    func switchIdentity(to name: String) {
        Task {
            do {
                let raw = try await client.request(method: "identity.use", params: ["name": AnyEncodable(name)])
                messages = []
                seenMessageIDs.removeAll()
                recordingURLs = [:]
                fileURLs = [:]
                identityId = raw?["identity"]?["id"]?.stringValue ?? name
                if let status = try? await client.status(), status.ready { selfPeerId = status.identityName }
                if let id = try? await client.identityId() { identityId = id }
                await hydrateHistory()
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
        idfonLog("idfon event: type=\(event.type) peer=\(peerId) text=\(text.prefix(48))")
        let messageID = event.messageId ?? event.eventId
        // Daemon message ids are sender-local (an eve holder restarts its
        // counter), so qualify by sender: deduping on the bare id silently
        // dropped a new message that reused an id seen from another sender.
        guard seenMessageIDs.insert("\(peerId)|\(messageID)").inserted else { return }
        // Call-control traffic (live invites, call_started/stopped) routes
        // to the call state machines; never shown as chat history. Invites
        // replayed after a relaunch are stale (app was closed when they
        // arrived) — ring only fresh ones, matching the GUI's drain logic.
        if LiveInvite.parse(text) != nil {
            idfonLog("idfon event: live invite stale=\(isStaleInvite(event))")
            if isStaleInvite(event) { return }
            LiveCall.shared.handleEnvelope(peer: peerId, text)
            VideoCall.shared.handleEnvelope(peer: peerId, text)
            return
        }
        if text == "call_started" || text == "call_stopped" {
            if isStaleControl(event) { return }
            LiveCall.shared.handleControl(peer: peerId, text)
            VideoCall.shared.handleEnvelope(peer: peerId, text)
            return
        }
        // A turn can carry reply text plus one or more trailing envelopes
        // (a transcript followed by an artifact, say). Keep the first part on
        // the event id so replay dedupe still holds.
        let timestamp = Double(event.timestamp).map(Date.init(timeIntervalSince1970:)) ?? Date()
        // Cache with the session log so history survives the daemon's temporary
        // event buffer (opt-in persistence via SessionStore.persistLogs).
        SessionStore.shared.append(
            identity: identityId,
            conversation: event.conversationId,
            SessionStore.StoredMessage(
                id: messageID, peerId: peerId, text: text, outgoing: false,
                timestamp: timestamp, conversation: event.conversationId))
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
            } else if let point = PointEnvelope.decode(envelope) {
                if let handler = onPoint {
                    handler(point, peerId)
                } else {
                    pendingPoints[peerId, default: []].append(point)
                }
                continue
            } else if let show = ShowEnvelope.decode(envelope) {
                if let handler = onShow {
                    handler(show, peerId)
                } else {
                    pendingShows[peerId, default: []].append(show)
                }
                continue
            } else if let screenshot = ScreenshotEnvelope.decode(envelope) {
                if let handler = onScreenshot {
                    handler(screenshot, peerId)
                } else {
                    pendingScreenshots[peerId, default: []].append(screenshot)
                }
                continue
            } else if SpeakEnvelope.decode(envelope) != nil {
                // Spoken output from the `speak` tool: not a chat bubble; the
                // voice path plays it (docs/session-context.md).
                continue
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
            messages.append(ChatMessage(id: partID, peerId: peerId, kind: part.1, outgoing: false, status: nil, timestamp: timestamp, conversation: event.conversationId))
            switch part.1 {
            case .recording(let ticket, _):
                onBanner?("Received voice message")
                fetchRecording(ticket: ticket)
            case .file(let ticket, let name, let sizeBytes):
                onBanner?("Received file")
                fetchFile(ticket: ticket, name: name, sizeBytes: sizeBytes)
            case .artifact:
                onBanner?("Received artifact")
            default:
                break
            }
        }
        notifyObservers()
    }

    /// Accept a directory invite: add the holder as a peer (with the chat
    /// grants) and store the subject-bound capability ticket so sends to it
    /// pass the holder's ingress gate.
    func acceptInvite(_ invite: ContactInvite) {
        Task { [client] in
            do {
                let identity = (try? await client.identityId()) ?? identityId
                try await client.addChannel(name: invite.name, ticketJSON: invite.contactJSON, identity: identity)
                _ = CapabilityTickets.store(invite.ticketJSON, for: invite.endpointId)
                onBanner?("Added \(invite.name)")
            } catch {
                idfonError("idfon invite: accept failed \(invite.name): \(error)")
                onBanner?("Could not add \(invite.name)")
            }
        }
    }

    /// Replayed call controls older than 60s belong to past sessions.
    private func isStaleControl(_ event: Event) -> Bool {
        guard let ts = Double(event.timestamp), ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts > 60
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
                idfonError("idfon: recording fetch failed \(ticket.prefix(16))...")
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
        let transcript = CallTranscript(callId: callId, turnId: turnId, role: role, text: text, final: true)
        let kind = MessageKind.callTranscript(transcript)
        if let messageID, let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].kind = kind
        } else {
            let id = "spoken-\(turnId)"
            guard !messages.contains(where: { $0.id == id }) else { return }
            messages.append(ChatMessage(id: id, peerId: peerId, kind: kind,
                                        outgoing: role != "agent", timestamp: Date()))
        }
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
            idfonLog("idfon file: received name=\(safe) size=\(sizeBytes)")
        }
    }

    func cacheFile(_ ticket: String, url: URL) {
        fileURLs[ticket] = url
        notifyObservers()
    }

    private static func readKey(_ id: String) -> String { "idfon.chat.read.\(id)" }

    func markRead(_ conversation: Conversation) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.readKey(conversation.id))
        notifyObservers()
    }

    func unreadCount(for conversation: Conversation) -> Int {
        let readAt = UserDefaults.standard.double(forKey: Self.readKey(conversation.id))
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

    /// Rebuilds chat items from one cached session-log line. Mirrors the split
    /// in `ingest` (preamble text plus trailing envelopes).
    private func restore(_ stored: SessionStore.StoredMessage) {
        guard seenMessageIDs.insert("\(stored.peerId)|\(stored.id)").inserted else { return }
        let (preamble, envelopes) = MessageBody.parse(stored.text)
        var parts: [(String, MessageKind)] = []
        if let preamble { parts.append((preamble, .text(preamble))) }
        for envelope in envelopes { parts.append((envelope, MessageKind.parse(envelope))) }
        if parts.isEmpty { parts.append((stored.text, .text(stored.text))) }
        for (index, part) in parts.enumerated() {
            let partID = index == 0 ? stored.id : "\(stored.id)#\(index)"
            if case .callTranscript(let transcript) = part.1,
               let existing = messages.firstIndex(where: {
                   if case .callTranscript(let current) = $0.kind { return current.turnId == transcript.turnId }
                   return false
               }) {
                messages[existing].kind = part.1
                continue
            }
            messages.append(ChatMessage(
                id: partID, peerId: stored.peerId, kind: part.1,
                outgoing: stored.outgoing, status: nil,
                timestamp: stored.timestamp, conversation: stored.conversation))
        }
    }

    private func hydrateHistory() async {
        // App-side session cache first; the daemon replay below dedupes against
        // these ids, so restored history is not appended twice.
        for stored in SessionStore.shared.load(identity: identityId) {
            restore(stored)
        }
        guard let events = try? await client.events(after: nil) else { return }
        for event in events.sorted(by: { (Double($0.timestamp) ?? 0) < (Double($1.timestamp) ?? 0) }) {
            cursor = event.cursor
            // Call invites/control are live-only. Replaying them on startup
            // can resurrect an old call and steal the state machine from a
            // newly launched caller.
            if event.messageText.map({ LiveInvite.parse($0) != nil || $0 == "call_started" || $0 == "call_stopped" }) == true { continue }
            ingest(event)
        }
    }

    private func runLoop() async {
        while true {
            do {
                // Poll retained events instead of relying solely on the daemon
                // long-poll. This keeps the AppKit client alive across daemon
                // restarts and catches return-leg call signals deterministically.
                let events = try await client.events(after: cursor)
                if events.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    for event in events.sorted(by: { (Double($0.timestamp) ?? 0) < (Double($1.timestamp) ?? 0) }) {
                        cursor = event.cursor
                        ingest(event)
                    }
                }
            } catch let error as DaemonClient.DaemonError {
                if let message = error.errorDescription, message.contains("cursor") {
                    cursor = nil
                } else {
                    idfonError("idfon events: poll failed, backing off: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch {
                idfonLog("idfon events: unexpected error: \(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}