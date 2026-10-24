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
            // `caller_id` derives from the presented ticket (RingTicket): a
            // contact ticket binds it as `subject`, a self-issued statement as
            // `issuer` — which is also the `sender.peer_id` message events
            // carry, so the push report and the invite envelope dedupe onto
            // one call. The identity key and the iroh endpoint id are
            // different ids (#56); any other derivation breaks the edge's
            // ticket checks.
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

    /// The stored contact ticket (the callee's statement about us), if any.
    private func contactTicket(for peer: String) -> RingTicket? {
        CapabilityTickets.rawTicketJSON(for: peer).flatMap { RingTicket(json: $0) }
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
        // A ref the ticket cannot claim (an endpoint-id spelling — the ticket
        // is issued by the identity id) must not fail the refs that can:
        // some claim beats a retry storm, and the claimed refs are the form
        // rings address (the peer record's id).
        var claimed = 0
        for account in await accountRefs(issuer: statement.issuer) {
            let url = EdgeClient.resourceURL(baseURL: base, account: account, path: "/_push/register")
            if await postJSON(
                url: url, ticket: statement.raw, body: ["voip_token": token, "topic": Self.topic])
            {
                claimed += 1
            }
        }
        return claimed > 0
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

    // The SDK imports this requirement with a `completion:` label; the Swift
    // name must match it exactly or the delegate never receives classic
    // pushes (the "nearly matches" selector mismatch). The @objc selector
    // pins the ObjC name older runtimes dispatch.
    @objc(pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:)
    func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType, completion: @escaping () -> Void
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
        // runs once the system has the call. But PushKit kills the app when
        // completion is late (~1.5s budget; the #55 death: the report landed
        // and the call UI appeared, then the process died ~2s later because
        // completion was still queued behind a busy main actor). So a deadline
        // fallback exits the callback on time even when main stalls — exactly
        // one of the two paths runs it.
        let done = Once(completion)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { done.run() }
        Task { @MainActor in
            if cancel {
                // End the ringing call in one turn. A cancel for a call that
                // is already gone must not resurrect it (report-then-end
                // flash) — but it must still end in a *reported* call: every
                // VoIP push that doesn't counts against the channel, and
                // PushKit then stops delivering to a suspended app entirely
                // (observed: ring pushes accepted by APNs, delegate never
                // called, until the push stream goes quiet and it heals).
                if !CallKitController.shared.cancelFromPush(callUUID: callUUID) {
                    CallKitController.shared.presentPush(
                        callUUID: callUUID,
                        callerId: dict["caller_id"] as? String ?? "",
                        hasVideo: (dict["has_video"] as? Bool) ?? false,
                        endImmediately: true)
                }
            } else {
                let callerId = dict["caller_id"] as? String ?? ""
                let hasVideo = (dict["has_video"] as? Bool) ?? false
                // The arrival transport decides the surface (#7): the invite
                // envelope is queued before the ring push is sent, so on a
                // live app it arrives first and the Bar owns that ring — a
                // system bar must never appear over it. A push for a call the
                // machines do not own yet reports the system bar (the
                // suspended-phone case): the app can be deactivated at any
                // moment, so the system ring must exist before that happens.
                let uuid = UUID(uuidString: callUUID) ?? CallUUID.from(ticket: callUUID)
                func ownedByBar(_ generation: String?) -> Bool {
                    guard let generation else { return false }
                    return CallUUID.from(ticket: generation) == uuid
                }
                let barOwnsCall = ownedByBar(LiveCall.shared.callGeneration)
                    || ownedByBar(VideoCall.shared.callGeneration)
                if barOwnsCall, !mustReport {
                    idfonLog("idfon push: ring already arrived over iroh; the Bar owns it — no system bar")
                } else if IncomingCallRouter.shared.ringsViaSystem(for: callerId) {
                    CallKitController.shared.presentPush(
                        callUUID: callUUID, callerId: callerId, hasVideo: hasVideo)
                } else if mustReport {
                    // Apple demands a reported call for this push. Report and
                    // KEEP it: the report-then-end flash (#58) looked like a
                    // call the user could answer but ended under them
                    // (the #51 E2E "blurry call screen"). If no invite lands,
                    // the caller's cancel push or the 20s pending-answer guard
                    // closes it; the Bar ring is presentation-only.
                    CallKitController.shared.presentPush(
                        callUUID: callUUID, callerId: callerId, hasVideo: hasVideo)
                } else {
                    idfonLog("idfon push: bar-mode channel \(callerId); no system ring")
                }
            }
            done.run()
        }
    }

    /// Runs the push completion exactly once: the main-actor path and the
    /// deadline fallback race for it.
    private final class Once {
        private let lock = NSLock()
        private var body: (() -> Void)?
        init(_ body: @escaping () -> Void) { self.body = body }
        func run() {
            lock.lock()
            let body = self.body
            self.body = nil
            lock.unlock()
            body?()
        }
    }

    // MARK: - Identity / tickets

    /// Every id this device is known by — for **each** identity (a device
    /// hosts several and calls are directed at identities, donpark/idfon#62
    /// thread): the peer id (`sender.peer_id`, what message events carry) and
    /// the iroh endpoint id (what contact records key on when the two
    /// differ). Registering only the active identity leaves calls to the
    /// others with no wake channel.
    private func accountRefs(issuer: String) async -> [String] {
        var refs: [String] = []
        var seen = Set<String>()
        func add(_ ref: String?) {
            guard let ref, !ref.isEmpty, seen.insert(ref).inserted else { return }
            refs.append(ref)
        }
        add(issuer)
        if let raw = try? await client.request(method: "identities")?["identities"]?.asArray {
            for entry in raw {
                add(entry["public_key"]?.stringValue)
                add(entry["endpoint_id"]?.stringValue)
            }
        }
        return refs
    }

    /// A self-issued capability ticket: a signed statement by this identity
    /// (the edge verifies issuer + signature, no shared secret).
    private func selfIssuedStatement() async throws -> RingTicket? {
        let raw = try await client.request(method: "capability.ticket", params: [
            "capabilities": AnyEncodable([AnyEncodable("message.send")]),
        ])
        guard let ticket = raw?["ticket"],
              let data = try? JSONEncoder().encode(ticket),
              let text = String(data: data, encoding: .utf8),
              let parsed = RingTicket(json: text)
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
