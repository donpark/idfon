import Foundation

/// Per-channel incoming-call routing seam
/// (docs/ui-design-notes.md §6, "Incoming-call handling: two modes").
///
/// The mode selects who owns incoming-ring *presentation* for a channel,
/// not how the call is transported: both modes funnel into the same call
/// state machines, which stay the source of truth — the router mirrors their
/// accept condition before reporting a ring to CallKit. Bar is the default
/// mode; a channel whose CallKit presentation fails falls back to the Bar
/// (`forceBarFallback`), an explicit switch, never a silent mode change.
@MainActor
final class IncomingCallRouter {
    static let shared = IncomingCallRouter()

    /// The CallKit platform gate (docs/callkit-integration.md): iOS can
    /// present system rings at all. A CallKit-mode invite or PushKit wake
    /// reports the same ticket-derived system call.
    @MainActor
    enum CallKitIncomingPresenter {
        static let isAvailable = true
    }

    private let client = IdfonClient()
    /// Cached `[ref: IncomingCallMode]` keyed by every ref a peer is known
    /// by (id, endpoint id, aliases — same flattening as `names`, #47);
    /// unknown peers resolve to `.bar`.
    private var modes: [String: IncomingCallMode] = [:]
    /// Display names by every ref a peer is known by (`id`, endpoint id,
    /// aliases): a push or envelope can arrive under either identity, and a
    /// push-first wake resolves names with no daemon round-trip in the same
    /// turn as the report. Persisted across launches for the same reason.
    private var names: [String: String] = [:]
    /// Channels whose CallKit presentation failed; the Bar serves them.
    private var barFallback: Set<String> = []

    private static let namesKey = "idfon.peerNamesByRef"
    private static let modesKey = "idfon.peerModes"

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        // Modes persist like names: a push wake has no daemon round-trip in
        // the same turn as the report (#57), and the Bar controller that used
        // to be the only refresher does not exist yet in a woken app.
        let rawModes = UserDefaults.standard.dictionary(forKey: Self.modesKey) as? [String: String] ?? [:]
        modes = rawModes.compactMapValues(IncomingCallMode.init(rawValue:))
    }

    func mode(for peerId: String) -> IncomingCallMode { modes[peerId] ?? .bar }

    /// Display name for the system call UI, or nil when no named peer matches.
    func name(for ref: String) -> String? { names[ref] }

    /// A configured system-call channel uses CallKit for outgoing and live
    /// incoming calls. A failed CallKit presentation falls back to the Bar.
    func ownsPresentation(for peerId: String) -> Bool {
        mode(for: peerId).usesCallKit && canPresentCallKit(for: peerId)
    }

    func canPresentCallKit(for peerId: String) -> Bool {
        CallKitIncomingPresenter.isAvailable && !barFallback.contains(peerId)
    }

    /// Whether a delivered VoIP push can be shown through CallKit. The
    /// caller's per-contact mode gates push creation; the receiver falls back
    /// to its Bar only after a CallKit presentation failure.
    func ringsViaSystem(for ref: String) -> Bool {
        !barFallback.contains(ref)
    }

    /// CallKit refused the call (report or transaction failed): the Bar takes
    /// over. The channel's mode never changes silently — the presenter does.
    func forceBarFallback(_ peerId: String) {
        idfonLog("idfon incoming-call mode: \(peerId) CallKit presentation failed; presenting in the Bar")
        barFallback.insert(peerId)
    }

    /// Refreshes the cached modes and names from the daemon's peer records.
    func refreshModes() async {
        guard let peers = try? await client.peers() else { return }
        modes = peers.reduce(into: [:]) { table, peer in
            let mode = peer.incomingCallMode
            for ref in PeerRefFlattening.refs(
                id: peer.id, endpointId: peer.endpointId, aliases: peer.aliases
            ) {
                table[ref] = mode
            }
        }
        names = peers.reduce(into: [:]) { table, peer in
            guard let name = peer.name, !name.isEmpty else { return }
            for ref in PeerRefFlattening.refs(
                id: peer.id, endpointId: peer.endpointId, aliases: peer.aliases
            ) {
                table[ref] = name
            }
        }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
        UserDefaults.standard.set(modes.mapValues(\.wireValue), forKey: Self.modesKey)
    }

    /// Routes an invite from `peerId` and hands it to the call machines.
    /// Report the same ticket-derived UUID before machine notifications so a
    /// CallKit channel has one system ring whether its push or iroh invite wins.
    func route(peerId: String, envelope text: String) {
        idfonLog("idfon incoming-call route peer=\(peerId) mode=\(mode(for: peerId).rawValue)")
        let machinesIdle: Bool
        if case .idle = LiveCall.shared.state, VideoCall.shared.state == .idle {
            machinesIdle = true
        } else {
            machinesIdle = false
        }
        if machinesIdle, let invite = LiveInvite.parse(text), invite.isStart,
           !invite.isReturn, !invite.ticket.isEmpty, invite.callMode?.usesCallKit == true,
           canPresentCallKit(for: peerId) {
            CallKitController.shared.presentIncoming(
                callUUID: CallUUID.from(ticket: invite.ticket).uuidString,
                callerId: peerId, hasVideo: invite.isCall)
        }
        LiveCall.shared.handleEnvelope(peer: peerId, text)
        VideoCall.shared.handleEnvelope(peer: peerId, text)
        // A CallKit answer that beat the invite completes now that a machine
        // can answer (docs/callkit-integration.md, P2).
        CallKitController.shared.envelopeArrived()
    }

    /// Sets a channel's incoming-call mode and refreshes the cache.
    func setMode(_ mode: IncomingCallMode, for peerId: String) async throws {
        try await client.setIncomingCallMode(ref: peerId, mode)
        modes[peerId] = mode
        barFallback.remove(peerId) // a fresh choice re-arms CallKit presentation
    }
}
