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

    /// The CallKit presentation gate (docs/callkit-integration.md).
    @MainActor
    enum CallKitIncomingPresenter {
        static let isAvailable = true

        static func present(peerId: String, name: String?, invite: LiveInvite) {
            CallKitController.shared.presentIncoming(peerId: peerId, name: name, invite: invite)
        }
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

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }

    func mode(for peerId: String) -> IncomingCallMode { modes[peerId] ?? .bar }

    /// Display name for the system call UI, or nil when no named peer matches.
    func name(for ref: String) -> String? { names[ref] }

    /// CallKit owns incoming-ring presentation for this channel.
    func ownsPresentation(for peerId: String) -> Bool {
        mode(for: peerId) == .callKit
            && CallKitIncomingPresenter.isAvailable
            && !barFallback.contains(peerId)
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
            for ref in [peer.id, peer.endpointId].compactMap({ $0 }) + (peer.aliases ?? []) {
                table[ref] = mode
            }
        }
        names = peers.reduce(into: [:]) { table, peer in
            guard let name = peer.name, !name.isEmpty else { return }
            for ref in [peer.id, peer.endpointId].compactMap({ $0 }) + (peer.aliases ?? []) {
                table[ref] = name
            }
        }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }

    /// Routes an invite envelope from `peerId`: a fresh incoming invite on a
    /// `call_kit` channel is reported to CallKit in the same turn and then
    /// handed to the machines — the mode governs presentation, not transport.
    /// Only invites go through here; `call_started`/`call_stopped` stay direct
    /// to both machines.
    func route(peerId: String, envelope text: String) {
        let viaCallKit = ownsPresentation(for: peerId)
        idfonLog("idfon incoming-call route peer=\(peerId) mode=\(mode(for: peerId).rawValue) callkit=\(viaCallKit)")
        if viaCallKit,
           let invite = LiveInvite.parse(text),
           invite.isStart, !invite.isReturn, !invite.ticket.isEmpty,
           machineWouldAccept(invite: invite, from: peerId) {
            CallKitIncomingPresenter.present(peerId: peerId, name: name(for: peerId), invite: invite)
        }
        LiveCall.shared.handleEnvelope(peer: peerId, text)
        VideoCall.shared.handleEnvelope(peer: peerId, text)
        // A push-first wake answered while the invite was in flight completes
        // now that a machine can answer (docs/callkit-integration.md, P2).
        CallKitController.shared.envelopeArrived()
    }

    /// Mirrors the machines' accept condition (they remain the source of
    /// truth; this only avoids reporting a ring the machines would drop).
    private func machineWouldAccept(invite: LiveInvite, from peerId: String) -> Bool {
        if invite.isCall {
            return VideoCall.shared.state == .idle
                || (VideoCall.shared.state == .incoming && VideoCall.shared.activePeer == peerId)
        }
        guard invite.media == nil else { return false } // file-share invites are not calls
        return LiveCall.shared.state == .idle
            || LiveCall.shared.state == .incoming(peer: peerId)
    }

    /// Sets a channel's incoming-call mode and refreshes the cache.
    func setMode(_ mode: IncomingCallMode, for peerId: String) async throws {
        try await client.setIncomingCallMode(ref: peerId, mode)
        modes[peerId] = mode
        barFallback.remove(peerId) // a fresh choice re-arms CallKit presentation
    }
}
