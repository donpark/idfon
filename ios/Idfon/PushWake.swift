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

    /// The call connected: any ring is answered, nothing to retract.
    func callConnected() { pendingRing = nil }

    private func send(peer: String, action: String, callUUID: String, hasVideo: Bool) {
        Task {
            guard let base = EdgeClient.shared.baseURL else { return }
            guard let ref = try? await selfRef() else { return }
            var ticket = contactTicket(for: peer, callerId: ref)
            if ticket == nil { ticket = try? await selfIssuedTicket() }
            guard let ticket else { return }
            var body: [String: Any] = ["call_uuid": callUUID, "caller_id": ref]
            if action == "ring" { body["has_video"] = hasVideo }
            let url = EdgeClient.resourceURL(baseURL: base, account: peer, path: "/_push/\(action)")
            await postJSON(url: url, ticket: ticket, body: body)
        }
    }

    /// The stored contact ticket, unless it is bound to an older identity of
    /// ours (then the edge would refuse it and a self-issued statement wins).
    private func contactTicket(for peer: String, callerId: String) -> String? {
        guard let json = CapabilityTickets.rawTicketJSON(for: peer),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        if let subject = object["subject"] as? String, !subject.isEmpty, subject != callerId {
            return nil
        }
        return json
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
        guard let ref = try? await selfRef(), let ticket = try? await selfIssuedTicket() else {
            return false
        }
        let url = EdgeClient.resourceURL(baseURL: base, account: ref, path: "/_push/register")
        return await postJSON(
            url: url, ticket: ticket, body: ["voip_token": token, "topic": Self.topic])
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
                  let ref = try? await selfRef(),
                  let ticket = try? await selfIssuedTicket()
            else { return }
            let url = EdgeClient.resourceURL(baseURL: base, account: ref, path: "/_push/unregister")
            await postJSON(url: url, ticket: ticket, body: ["voip_token": token])
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
                        hasVideo: (dict["has_video"] as? Bool) ?? false)
                    CallKitController.shared.cancelFromPush(callUUID: callUUID)
                }
            } else {
                CallKitController.shared.presentPush(
                    callUUID: callUUID,
                    callerId: dict["caller_id"] as? String ?? "",
                    hasVideo: (dict["has_video"] as? Bool) ?? false)
            }
            completion()
        }
    }

    // MARK: - Identity / tickets

    /// This device's endpoint id — the account ref it registers under and
    /// rings as.
    private func selfRef() async throws -> String {
        let raw = try await client.request(method: "status")
        if let endpoint = raw?["identity"]?["endpoint_id"]?.stringValue, !endpoint.isEmpty {
            return endpoint
        }
        return try await client.identityId()
    }

    /// A self-issued capability ticket: a signed statement by this identity
    /// (the edge verifies issuer + signature, no shared secret).
    private func selfIssuedTicket() async throws -> String {
        let raw = try await client.request(method: "capability.ticket", params: [
            "capabilities": AnyEncodable([AnyEncodable("message.send")]),
        ])
        guard let ticket = raw?["ticket"],
              let data = try? JSONEncoder().encode(ticket),
              let text = String(data: data, encoding: .utf8)
        else {
            idfonError("idfon push: capability.ticket returned no ticket")
            return ""
        }
        return text
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
