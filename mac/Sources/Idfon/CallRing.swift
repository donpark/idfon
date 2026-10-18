import Foundation

/// The VoIP push wake channel, caller side (docs/callkit-integration.md, P2).
///
/// The mac presents calls in-app (its system-call surface is deferred), but it
/// must still *ring* a `call_kit` peer's devices: after the invite envelope is
/// queued the caller posts `/_push/ring` to its configured edge, and
/// `/_push/cancel` if the call goes idle before connecting. Auth is the
/// callee's contact ticket when this device holds one (subject-checked), else
/// a self-issued statement — the edge's ring policy. Payloads carry
/// identifiers only; the callee resolves names locally.
enum CallRing {
    private static let client = DaemonClient()
    /// The ring this device sent and that is not answered yet.
    private static var pendingRing: (peer: String, callUUID: String)?

    /// Ring the peer's registered devices — call after the invite is queued.
    /// `ref` resolves to the canonical peer id (ring URLs and ticket keys are
    /// id-keyed); `inviteTicket` is the media ticket the invite carries, so
    /// the callee's push report and the envelope land on one system call.
    /// Every call ring-pushes per platform design: iOS callees get the system
    /// call UI (and the wake when terminated); macOS callees register no VoIP
    /// token and simply ring in their app's Bar.
    static func ring(peer ref: String, inviteTicket: String, hasVideo: Bool) async {
        guard EdgeClient.shared.baseURL != nil else {
            idfonLog("idfon ring: no edge configured; skipping")
            return
        }
        guard let id = await peerRecord(for: ref) else {
            idfonLog("idfon ring: \(ref) is not a known peer; no wake")
            return
        }
        let callUUID = CallUUID.from(ticket: inviteTicket).uuidString
        idfonLog("idfon ring: peer=\(id) call=\(callUUID)")
        pendingRing = (id, callUUID)
        send(peer: id, action: "ring", callUUID: callUUID, hasVideo: hasVideo)
    }

    /// Retract the unanswered ring (caller hung up before answer).
    static func cancelRing() {
        guard let pending = pendingRing else { return }
        pendingRing = nil
        idfonLog("idfon ring: cancel call=\(pending.callUUID)")
        send(peer: pending.peer, action: "cancel", callUUID: pending.callUUID, hasVideo: false)
    }

    /// The call connected: the ring is over — retract it so the identity's
    /// other devices stop ringing (#46). A device that answered ignores the
    /// ring-over (its machine is already in call).
    static func callConnected() { cancelRing() }

    /// The peer record behind a ref: canonical id.
    private static func peerRecord(for ref: String) async -> String? {
        guard let list = try? await client.request(method: "peers"),
            let peers = list["peers"]?.asArray
        else { return nil }
        guard let match = peers.first(where: {
            $0["id"]?.stringValue == ref || $0["name"]?.stringValue == ref
                || $0["aliases"]?.asArray?.contains { $0.stringValue == ref } == true
        }), let id = match["id"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }

    private static func send(peer: String, action: String, callUUID: String, hasVideo: Bool) {
        Task {
            guard let base = EdgeClient.shared.baseURL else { return }
            // `caller_id` derives from the presented ticket (RingTicket): a
            // contact ticket binds it as `subject`, a self-issued statement as
            // `issuer` — which is also the `sender.peer_id` message events
            // carry, so the callee's push report and envelope dedupe onto one
            // call. The identity key and the iroh endpoint id are different
            // ids (#56); any other derivation breaks the edge's ticket checks.
            guard let ticket = RingTicket.presentation(
                contact: contactTicket(for: peer),
                issued: try? await selfIssuedStatement())
            else { return }
            var body: [String: Any] = ["call_uuid": callUUID, "caller_id": ticket.callerId]
            if action == "ring" { body["has_video"] = hasVideo }
            let url = EdgeClient.resourceURL(baseURL: base, account: peer, path: "/_push/\(action)")
            await postJSON(url: url, ticket: ticket.raw, body: body)
        }
    }

    /// A self-issued capability ticket: a signed statement by this identity
    /// (the edge verifies issuer + signature, no shared secret).
    private static func selfIssuedStatement() async throws -> RingTicket? {
        let raw = try await client.request(method: "capability.ticket", params: [
            "capabilities": AnyEncodable([AnyEncodable("message.send")]),
        ])
        guard let ticket = raw?["ticket"],
            let data = try? JSONEncoder().encode(ticket),
            let text = String(data: data, encoding: .utf8),
            let parsed = RingTicket(json: text)
        else {
            idfonError("idfon ring: capability.ticket returned no ticket")
            return nil
        }
        return parsed
    }

    /// The stored contact ticket (the callee's statement about us), if any.
    private static func contactTicket(for peer: String) -> RingTicket? {
        CapabilityTickets.rawTicketJSON(for: peer).flatMap(RingTicket.init(json:))
    }

    private static func postJSON(url: URL, ticket: String, body: [String: Any]) async {
        guard !ticket.isEmpty else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(ticket, forHTTPHeaderField: "x-idfon-ticket")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            idfonLog("idfon ring: \(url.lastPathComponent) → \(status)")
        } catch {
            idfonLog("idfon ring: \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }
}
