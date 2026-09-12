import Foundation

/// Per-connection incoming-call routing seam
/// (docs/ui-design-notes.md §6, "Incoming-call handling: two modes").
///
/// The mode selects who owns incoming-ring *presentation* for a connection,
/// not how the call is transported: both modes funnel into the same call
/// state machines. Bar is the interim default until CallKit integration
/// lands. A connection configured for CallKit while the presenter is
/// unavailable is presented in the Bar and the deferral is logged — an
/// explicit, visible switch, never a silent mode change.
@MainActor
final class IncomingCallRouter {
    static let shared = IncomingCallRouter()

    /// The single gate for CallKit integration. No CallKit integration exists
    /// yet, so this is `false` and `present` is never reached; when one lands
    /// it flips this flag and the envelope is handed over here.
    enum CallKitIncomingPresenter {
        static let isAvailable = false

        /// Never called while `isAvailable == false`.
        static func present(peerId: String, text: String) {
            NSLog("idfon callkit presenter: present(\(peerId)) — unavailable stub reached")
        }
    }

    private let client = DaemonClient()
    /// Cached `[peerId: IncomingCallMode]`; unknown peers resolve to `.bar`.
    private var modes: [String: IncomingCallMode] = [:]
    /// Peers already told once that their CallKit mode is deferring to the Bar.
    private var deferralLogged: Set<String> = []

    private init() {}

    func mode(for peerId: String) -> IncomingCallMode { modes[peerId] ?? .bar }

    /// Refreshes the cached modes from the daemon's peer records.
    func refreshModes() async {
        guard let peers = try? await client.peers() else { return }
        modes = peers.reduce(into: [:]) { $0[$1.id] = $1.incomingCallMode }
    }

    /// Routes an invite envelope from `peerId` to the presenter its connection
    /// selects. Only invites go through here — `call_started`/`call_stopped`
    /// stay direct to both machines, since the mode governs presentation, not
    /// teardown.
    func route(peerId: String, envelope text: String) {
        if mode(for: peerId) == .callKit {
            if CallKitIncomingPresenter.isAvailable {
                CallKitIncomingPresenter.present(peerId: peerId, text: text)
                return
            }
            if deferralLogged.insert(peerId).inserted {
                NSLog("idfon incoming-call mode: \(peerId) is set to call_kit but CallKit is unavailable; presenting in the Bar")
            }
        }
        LiveCall.shared.handleEnvelope(peer: peerId, text)
        VideoCall.shared.handleEnvelope(peer: peerId, text)
    }

    /// Sets a connection's incoming-call mode and refreshes the cache.
    func setMode(_ mode: IncomingCallMode, for peerId: String) async throws {
        try await client.setIncomingCallMode(ref: peerId, mode)
        modes[peerId] = mode
        deferralLogged.remove(peerId) // re-arm the deferral log for any future CallKit selection
    }
}