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
    /// present system rings at all. Presentation happens only on the ring-push
    /// path (`presentPush`) — a ring that arrived over iroh never gets a
    /// system bar.
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

    /// CallKit owns incoming-ring presentation — always, per platform
    /// design (iOS: the system call UI is THE surface; macOS has no CallKit
    /// and uses the app's Bar instead). The only demotion is the fallback:
    /// a failed CallKit report hands the channel to the Bar
    /// (`forceBarFallback`, an explicit switch, never a silent mode change).
    func ownsPresentation(for peerId: String) -> Bool {
        CallKitIncomingPresenter.isAvailable
            && !barFallback.contains(peerId)
    }

    /// Whether this channel accepts a system ring at all. The **sender's**
    /// `call_mode` opt-in decides whether a channel rings (`ring()` is gated
    /// there); the receiver honors the ring unless its own CallKit
    /// presentation has failed for this channel (`barFallback`). The
    /// receiver's own mode governs only how *it* presents an arriving call
    /// when running (`ownsPresentation` on the envelope path) — gating the
    /// push on it broke the wake (the wire collapses unset into bar,
    /// donpark/idfon#47, #57).
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

    /// Routes an invite envelope from `peerId` and hands it to the machines.
    /// The arrival transport decides the surface (docs/callkit-integration.md
    /// #7): a ring that arrived over iroh never gets a CallKit bar — only the
    /// ring-push path reports one — so the Bar may ring it. Only invites go
    /// through here; `call_started`/`call_stopped` stay direct to both
    /// machines.
    func route(peerId: String, envelope text: String) {
        idfonLog("idfon incoming-call route peer=\(peerId) mode=\(mode(for: peerId).rawValue)")
        LiveCall.shared.handleEnvelope(peer: peerId, text)
        VideoCall.shared.handleEnvelope(peer: peerId, text)
        // A push-first wake answered while the invite was in flight completes
        // now that a machine can answer (docs/callkit-integration.md, P2).
        CallKitController.shared.envelopeArrived()
    }

    /// Sets a channel's incoming-call mode and refreshes the cache.
    func setMode(_ mode: IncomingCallMode, for peerId: String) async throws {
        try await client.setIncomingCallMode(ref: peerId, mode)
        modes[peerId] = mode
        barFallback.remove(peerId) // a fresh choice re-arms CallKit presentation
    }
}
