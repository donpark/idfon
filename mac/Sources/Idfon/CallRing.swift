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
    /// Non-`call_kit` channels get no wake.
    static func ring(peer ref: String, inviteTicket: String, hasVideo: Bool) async {
        guard EdgeClient.shared.baseURL != nil else {
            idfonLog("idfon ring: no edge configured; skipping")
            return
        }
        guard let match = await peerRecord(for: ref), match.usesWake else {
            idfonLog("idfon ring: \(ref) is not a call_kit channel; no wake")
            return
        }
        let callUUID = CallUUID.from(ticket: inviteTicket).uuidString
        idfonLog("idfon ring: peer=\(match.id) call=\(callUUID)")
        pendingRing = (match.id, callUUID)
        send(peer: match.id, action: "ring", callUUID: callUUID, hasVideo: hasVideo)
    }

    /// Retract the unanswered ring (caller hung up before answer).
    static func cancelRing() {
        guard let pending = pendingRing else { return }
        pendingRing = nil
        idfonLog("idfon ring: cancel call=\(pending.callUUID)")
        send(peer: pending.peer, action: "cancel", callUUID: pending.callUUID, hasVideo: false)
    }

    /// The call connected: any ring is answered, nothing to retract.
    static func callConnected() { pendingRing = nil }

    /// The peer record behind a ref: canonical id and whether the channel
    /// selects the system-call wake (`call_mode` on the record — the Bar is
    /// for people who are already here, docs/ui-design-notes.md §6).
    private static func peerRecord(for ref: String) async -> (id: String, usesWake: Bool)? {
        guard let list = try? await client.request(method: "peers"),
            let peers = list["peers"]?.asArray
        else { return nil }
        guard let match = peers.first(where: {
            $0["id"]?.stringValue == ref || $0["name"]?.stringValue == ref
                || $0["aliases"]?.asArray?.contains { $0.stringValue == ref } == true
        }), let id = match["id"]?.stringValue, !id.isEmpty else { return nil }
        return (id, match["call_mode"]?.stringValue == "call_kit")
    }

    private static func send(peer: String, action: String, callUUID: String, hasVideo: Bool) {
        Task {
            guard let base = EdgeClient.shared.baseURL else { return }
            // `caller_id` must come from the ticket itself: a contact ticket
            // binds it as `subject`, a self-issued statement as `issuer` —
            // which is also the `sender.peer_id` message events carry, so the
            // callee's push report and envelope dedupe onto one call. The
            // identity key and the iroh endpoint id are different ids; any
            // other derivation breaks the edge's ticket checks.
            let ticket: String
            let callerId: String
            if let contact = contactTicket(for: peer), let subject = contact.subject {
                ticket = contact.raw
                callerId = subject
            } else if let issued = try? await selfIssuedStatement() {
                ticket = issued.raw
                callerId = issued.issuer
            } else {
                return
            }
            var body: [String: Any] = ["call_uuid": callUUID, "caller_id": callerId]
            if action == "ring" { body["has_video"] = hasVideo }
            let url = EdgeClient.resourceURL(baseURL: base, account: peer, path: "/_push/\(action)")
            await postJSON(url: url, ticket: ticket, body: body)
        }
    }

    /// A ticket as it will be presented, with the fields the ring binds.
    private struct TicketRef {
        let raw: String
        let issuer: String
        let subject: String?
    }

    private static func parseTicket(_ json: String) -> TicketRef? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let issuer = object["issuer"] as? String, !issuer.isEmpty
        else { return nil }
        let subject = (object["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TicketRef(raw: json, issuer: issuer, subject: subject)
    }

    /// A self-issued capability ticket: a signed statement by this identity
    /// (the edge verifies issuer + signature, no shared secret).
    private static func selfIssuedStatement() async throws -> TicketRef? {
        let raw = try await client.request(method: "capability.ticket", params: [
            "capabilities": AnyEncodable([AnyEncodable("message.send")]),
        ])
        guard let ticket = raw?["ticket"],
            let data = try? JSONEncoder().encode(ticket),
            let text = String(data: data, encoding: .utf8),
            let parsed = parseTicket(text)
        else {
            idfonError("idfon ring: capability.ticket returned no ticket")
            return nil
        }
        return parsed
    }

    /// The stored contact ticket (the callee's statement about us), if any.
    private static func contactTicket(for peer: String) -> TicketRef? {
        CapabilityTickets.rawTicketJSON(for: peer).flatMap(parseTicket)
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
