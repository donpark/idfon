import Foundation
import PushKit

/// The VoIP push wake channel (docs/callkit-integration.md, P2).
///
/// Three jobs: register this device's PushKit token with its edge
/// (`/_push/register`), ring/cancel a peer's devices when calling a
/// `call_kit` channel (`/_push/ring`, `/_push/cancel`), and hand incoming
/// pushes to `CallKitController` — **immediately**: a VoIP push that does not
/// result in a reported call is grounds for app termination.
///
/// Auth is a capability ticket issued by the route's target ref (the edge's
/// `/_push/*` policy): a self-issued ticket for registration (only the
/// identity's holder may claim its wake channel) and, for ring/cancel, the
/// callee's contact ticket when this device holds one — else a self-issued
/// statement (accountable, rate-limited at the edge). The payload carries
/// identifiers only; display names resolve here from the local peer store.
final class PushWake: NSObject, PKPushRegistryDelegate {
    static let shared = PushWake()

    /// The app's VoIP topic: `<bundle-id>.voip` (tokens are per app bundle).
    static let topic = "com.idfon.ios.voip"

    private static let tokenKey = "idfon.push.token"

    private let client = IdfonClient()
    private var registry: PKPushRegistry?
    /// Last registered token (for unregister on invalidation).
    private var lastToken: String?
    /// The ring this device sent and that is not answered yet (caller side).
    private var pendingRing: (peer: String, callUUID: String)?

    /// Start PushKit registration (call once at launch). Without a configured
    /// edge (`-edgeurl`) nothing registers and no ring is sent — the Bar path
    /// is fully functional without push.
    func start() {
        guard registry == nil else { return }
        lastToken = UserDefaults.standard.string(forKey: Self.tokenKey)
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    // MARK: - Caller side (ring/cancel)

    /// Ring the peer's registered devices — call after the invite envelope is
    /// queued. `callUUID` must be `CallUUID.from(ticket)` of the invite, so the
    /// callee's push report and the envelope land on the same system call.
    func ring(peer: String, callUUID: String, hasVideo: Bool) {
        guard EdgeClient.shared.baseURL != nil else {
            idfonLog("idfon push: no edge configured; skipping ring")
            return
        }
        idfonLog("idfon push: ring peer=\(peer) call=\(callUUID)")
        pendingRing = (peer, callUUID)
        send(peer: peer, action: "ring", callUUID: callUUID, hasVideo: hasVideo)
    }

    /// Retract the unanswered ring (caller hung up before answer).
    func cancelRing() {
        guard let pending = pendingRing else { return }
        pendingRing = nil
        idfonLog("idfon push: cancel call=\(pending.callUUID)")
        send(peer: pending.peer, action: "cancel", callUUID: pending.callUUID, hasVideo: false)
    }

    /// The call connected: the ring is over — retract it so the identity's
    /// other devices stop ringing (#46). A device that answered ignores the
    /// ring-over (`cancelFromPush` leaves answered calls alone).
    func callConnected() { cancelRing() }

    private func send(peer: String, action: String, callUUID: String, hasVideo: Bool) {
        Task {
            guard let base = EdgeClient.shared.baseURL else { return }
            // `caller_id` must come from the ticket itself: a contact ticket
            // binds it as `subject`, a self-issued statement as `issuer` —
            // which is also the `sender.peer_id` message events carry, so the
            // push report and the invite envelope dedupe onto one call. The
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

    private func parseTicket(_ json: String) -> TicketRef? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let issuer = object["issuer"] as? String, !issuer.isEmpty
        else { return nil }
        let subject = (object["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TicketRef(raw: json, issuer: issuer, subject: subject)
    }

    /// The stored contact ticket (the callee's statement about us), if any.
    private func contactTicket(for peer: String) -> TicketRef? {
        CapabilityTickets.rawTicketJSON(for: peer).flatMap { parseTicket($0) }
    }

    // MARK: - Registration

    private func register(token: String) async {
        // The core may still be booting at launch: retry, then leave it until
        // the next launch or credential update re-tries.
        for _ in 0..<5 {
            if await registerOnce(token: token) { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        idfonError("idfon push: registration failed")
    }

    private func registerOnce(token: String) async -> Bool {
        guard let base = EdgeClient.shared.baseURL else { return true } // no edge: nothing to do
        guard let statement = try? await selfIssuedStatement() else { return false }
        for account in await accountRefs(issuer: statement.issuer) {
            let url = EdgeClient.resourceURL(baseURL: base, account: account, path: "/_push/register")
            guard await postJSON(
                url: url, ticket: statement.raw, body: ["voip_token": token, "topic": Self.topic])
            else { return false }
        }
        return true
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(
        _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        lastToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        Task { await register(token: token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP, let token = lastToken else { return }
        lastToken = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        Task {
            guard let base = EdgeClient.shared.baseURL,
                  let statement = try? await selfIssuedStatement()
            else { return }
            for account in await accountRefs(issuer: statement.issuer) {
                let url = EdgeClient.resourceURL(
                    baseURL: base, account: account, path: "/_push/unregister")
                await postJSON(url: url, ticket: statement.raw, body: ["voip_token": token])
            }
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType, withCompletionHandler completion: @escaping () -> Void
    ) {
        idfonLog("idfon push: incoming (classic) type=\(type.rawValue)")
        handlePush(payload.dictionaryPayload, mustReport: true, completion)
    }

    /// iOS 26.4+ delivers VoIP pushes through this variant — when the delegate
    /// does not implement it, the push is dropped before the app (verified on
    /// iOS 27.0.1). `metadata.mustReport` marks pushes that must end in a
    /// reported call; every ring is one.
    @available(iOS 26.4, *)
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingVoIPPushWith payload: PKPushPayload,
        metadata: PKVoIPPushMetadata,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        idfonLog("idfon push: incoming (voip) mustReport=\(metadata.mustReport)")
        handlePush(payload.dictionaryPayload, mustReport: metadata.mustReport, completion)
    }

    /// The classic delegate (pre-26.4): every VoIP push must end in a
    /// reported call there, so `mustReport` is carried as true.
    private func handlePush(
        _ dict: [AnyHashable: Any], mustReport: Bool, _ completion: @escaping () -> Void
    ) {
        let callUUID = dict["call_uuid"] as? String ?? ""
        let cancel = (dict["cancel"] as? Bool) == true
        idfonLog("idfon push: received call=\(callUUID) cancel=\(cancel) mustReport=\(mustReport)")
        // Report before anything else (Signal's rule) — the completion handler
        // runs once the system has the call.
        Task { @MainActor in
            if cancel {
                // End the ringing call in one turn. A cancel for a call that
                // is already gone must not resurrect it (report-then-end
                // flash): only a `mustReport` push needs a reported call.
                if !CallKitController.shared.cancelFromPush(callUUID: callUUID), mustReport {
                    CallKitController.shared.presentPush(
                        callUUID: callUUID,
                        callerId: dict["caller_id"] as? String ?? "",
                        hasVideo: (dict["has_video"] as? Bool) ?? false,
                        endImmediately: true)
                }
            } else {
                let callerId = dict["caller_id"] as? String ?? ""
                let hasVideo = (dict["has_video"] as? Bool) ?? false
                // The callee's own channel mode decides who owns the ring —
                // the sender's view of the channel may disagree (#47).
                if IncomingCallRouter.shared.ownsPresentation(for: callerId) {
                    CallKitController.shared.presentPush(
                        callUUID: callUUID, callerId: callerId, hasVideo: hasVideo)
                } else if mustReport {
                    // Apple demands a reported call for this push; report and
                    // end once the report completes (#58). The channel's Bar
                    // rings in-app when the envelope lands.
                    CallKitController.shared.presentPush(
                        callUUID: callUUID, callerId: callerId, hasVideo: hasVideo,
                        endImmediately: true)
                } else {
                    idfonLog("idfon push: bar-mode channel \(callerId); no system ring")
                }
            }
            completion()
        }
    }

    // MARK: - Identity / tickets

    /// Every id this device is known by: the ticket issuer (`sender.peer_id`,
    /// what message events carry) and the iroh endpoint id (what contact
    /// records key on when the two differ).
    private func accountRefs(issuer: String) async -> [String] {
        var refs = [issuer]
        if let raw = try? await client.request(method: "status"),
           let endpoint = raw["identity"]?["endpoint_id"]?.stringValue,
           !endpoint.isEmpty, endpoint != issuer {
            refs.append(endpoint)
        }
        return refs
    }

    /// A self-issued capability ticket: a signed statement by this identity
    /// (the edge verifies issuer + signature, no shared secret).
    private func selfIssuedStatement() async throws -> TicketRef? {
        let raw = try await client.request(method: "capability.ticket", params: [
            "capabilities": AnyEncodable([AnyEncodable("message.send")]),
        ])
        guard let ticket = raw?["ticket"],
              let data = try? JSONEncoder().encode(ticket),
              let text = String(data: data, encoding: .utf8),
              let parsed = parseTicket(text)
        else {
            idfonError("idfon push: capability.ticket returned no ticket")
            return nil
        }
        return parsed
    }

    // MARK: - HTTP

    @discardableResult
    private func postJSON(url: URL, ticket: String, body: [String: Any]) async -> Bool {
        guard !ticket.isEmpty else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(ticket, forHTTPHeaderField: "x-idfon-ticket")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            idfonLog("idfon push: \(url.lastPathComponent) → \(status)")
            return (200..<300).contains(status)
        } catch {
            idfonLog("idfon push: \(url.lastPathComponent) failed: \(error.localizedDescription)")
            return false
        }
    }
}
