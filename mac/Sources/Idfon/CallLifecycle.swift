import Foundation

/// Pure call-lifecycle state machine shared by the audio and video call hosts
/// (mac/Sources/Idfon/Calls.swift, ios/Idfon/{LiveCall,VideoCall}.swift).
///
/// The hosts own capture, transport and UI; this owns the *lifecycle*: the
/// phase, who the peer is, the call's immutable generation ticket, and the
/// single exit path. Every transition returns the effects the host must run,
/// so no flow can end a call without the stop it owes the peer (the "caller
/// stayed connected after the callee hung up" bug class) and no flow can end
/// it without stopping media (lingering state).
///
/// Rule of the machine: a phase carries its own data (an incoming call *is*
/// its invite), so the wedges the old parallel fields allowed — an incoming
/// call whose invite was already cleared, a stop correlated against a ticket
/// that a re-publish had replaced — cannot be expressed.
struct CallLifecycle {
    // MARK: - State

    enum Phase: Equatable {
        case idle
        /// Incoming invite awaiting answer; the invite is the state's data, so
        /// "ringing but the invite is gone" cannot exist (donpark/idfon#51).
        case incoming(Invite)
        /// Outgoing call: publishing or published, no leg from the peer yet.
        case dialing(peer: String)
        /// Two-way call in progress.
        case connected(peer: String)
        /// One-way watch session (video-file share); publishes nothing.
        case watching(peer: String)
    }

    /// A received `IDFON-LIVE/1 action=start` invite the host classified as
    /// its own (audio vs video is the host's filter, not this machine's).
    struct Invite: Equatable {
        /// Sender as the host knows it (the event's peer id).
        let peer: String
        /// The sender's publish ticket. For an incoming call this is the
        /// call's generation.
        let ticket: String
        /// The peer we called answered and publishes back. The flag rides the
        /// wire as `return=1` (the Rust holder sets it; Swift return legs do
        /// not), so acceptance never depends on it — phase and peer decide.
        let isReturn: Bool
        /// `media=video` one-way share: answering joins without publishing.
        let watchOnly: Bool
    }

    /// What the host must do after a transition.
    enum Effect: Equatable {
        /// The event was refused (dial while a call exists).
        case rejectedBusy
        /// Tell the peer the call is over. `ticket` is the call's generation;
        /// nil when the call never got one (ended before the publish landed) —
        /// the host then sends its legacy bare `call_stopped`.
        case sendStop(peer: String, ticket: String?)
        /// Join/watch `ticket`. `answersDial` is true when this leg is the
        /// peer's answer to our outgoing call (answer cue); false for a fresh
        /// ticket on an already-connected call (their re-publish).
        case join(ticket: String, answersDial: Bool)
        /// Tear down every local media resource (publishes, subscriptions,
        /// captures) and reset the send flags.
        case stopMedia
        /// A connected call ended: play the end cue.
        case endCue
        /// An unconnected ring or call ended: go quiet (donpark/idfon#15).
        case quiet
        /// A fresh ring is on: present it (tone, banner, oncoming hook).
        case ring(peer: String)
        /// State changed: refresh UI and call mirrors.
        case changed
        /// A stop named no call of ours: a push-first ring may outlive the
        /// machine, so end any transport-side ring too (donpark/idfon#45).
        case remoteEnded(peer: String, ticket: String?)
        /// A dropped or refused event, explained — never a silent drop.
        case log(String)
    }

    // MARK: - Fields

    private(set) var phase: Phase = .idle
    /// The call's identity: the dialer's publish ticket — known to both sides
    /// (the caller generated it, the callee received it in the invite). Set
    /// once when the call opens and never overwritten by later publishes:
    /// stops carry it, so correlation cannot drift mid-call (a re-publish used
    /// to swap it and the peer's hang-up then named an "older" call).
    private(set) var generation: String?
    /// Bumped whenever in-flight work is invalidated; async flows capture it
    /// and re-check it after every await.
    private(set) var epoch: Int = 0

    /// The call's peer in every non-idle phase.
    var peer: String? {
        switch phase {
        case .idle: return nil
        case .incoming(let invite): return invite.peer
        case .dialing(let peer), .connected(let peer), .watching(let peer): return peer
        }
    }

    /// True while any call (or ring) exists.
    var isBusy: Bool { phase != .idle }

    // MARK: - Transitions

    /// The only way state changes. Returns the effects the host must run.
    mutating func on(_ event: Event) -> [Effect] {
        switch event {
        case .dial(let peer):
            guard case .idle = phase else {
                return [.rejectedBusy, .log("dial refused: already in \(phaseName)")]
            }
            begin(.dialing(peer: peer), generation: nil)
            return [.changed]

        case .resolve(let peer):
            switch phase {
            case .incoming(let invite):
                phase = .incoming(Invite(
                    peer: peer, ticket: invite.ticket, isReturn: invite.isReturn,
                    watchOnly: invite.watchOnly))
            case .dialing:
                phase = .dialing(peer: peer)
            case .connected:
                phase = .connected(peer: peer)
            case .watching:
                phase = .watching(peer: peer)
            case .idle:
                return [.log("resolve ignored: no call")]
            }
            return [.changed]

        case .published(let ticket):
            // Only the caller's first publish names the call. The callee's own
            // publish and every re-publish carry their own tickets and must
            // never move the generation.
            if case .dialing = phase, generation == nil {
                generation = ticket
            }
            return []

        case .invite(let invite):
            return accept(invite)

        case .answer:
            guard case .incoming(let invite) = phase else {
                return [.log("answer ignored: no incoming call")]
            }
            begin(
                invite.watchOnly ? .watching(peer: invite.peer) : .connected(peer: invite.peer),
                generation: invite.ticket)
            return [.changed]

        case .hangUp:
            guard isBusy else { return [.log("hang up with no live call")] }
            return end(tellPeer: true)

        case .remoteStop(let from, let ticket):
            if case .idle = phase {
                return [.remoteEnded(peer: from, ticket: ticket)]
            }
            let names: Bool
            if let ticket, !ticket.isEmpty {
                // A ticketed stop is proof of the call it names (#60): match on
                // the generation alone, so a peer id that arrives under a
                // different ref can still end its call. An older call's stop
                // carries the old ticket and is ignored.
                names = ticket == generation
            } else {
                // Legacy bare `call_stopped`: no generation to match, only the
                // peer can vouch for it.
                names = from == peer
            }
            guard names else {
                return [.log("ignored stop from \(from) ticket=\(ticket ?? "none"): call is \(phaseName)")]
            }
            return end(tellPeer: false)

        case .fail(let reason):
            guard isBusy else { return [.log("failure with no live call: \(reason)")] }
            return [.log("call failed: \(reason)")] + end(tellPeer: true)

        case .abandon:
            guard isBusy else { return [] }
            return end(tellPeer: false)
        }
    }

    // MARK: - Private

    private var phaseName: String {
        switch phase {
        case .idle: return "idle"
        case .incoming: return "incoming"
        case .dialing: return "dialing"
        case .connected: return "connected"
        case .watching: return "watching"
        }
    }

    /// Opens a call or ring: the phase carries its data and the epoch moves,
    /// so any in-flight work from the previous call is void.
    private mutating func begin(_ newPhase: Phase, generation newGeneration: String?) {
        phase = newPhase
        generation = newGeneration
        epoch += 1
    }

    /// The single exit path. Every way out of a call goes through here, so no
    /// flow can skip the stop the peer is owed or leave media running.
    private mutating func end(tellPeer: Bool) -> [Effect] {
        let peer = self.peer
        let wasConnected: Bool
        if case .connected = phase { wasConnected = true } else { wasConnected = false }
        let ticket = generation
        phase = .idle
        generation = nil
        epoch += 1
        var effects: [Effect] = []
        if tellPeer, let peer {
            effects.append(.sendStop(peer: peer, ticket: ticket))
        }
        effects.append(.stopMedia)
        effects.append(wasConnected ? .endCue : .quiet)
        effects.append(.changed)
        return effects
    }

    /// An `action=start` invite: a leg on the running call, a superseding
    /// invite for a ring, or a new ring.
    private mutating func accept(_ invite: Invite) -> [Effect] {
        guard !invite.ticket.isEmpty else {
            return [.log("ignored invite without a ticket from \(invite.peer)")]
        }
        switch phase {
        case .dialing(let peer), .connected(let peer):
            guard invite.peer == peer else {
                return [.log("ignored invite from \(invite.peer): call is with \(peer)")]
            }
            // A leg on our call: the peer's answer to our dial (return leg or
            // their `call_started`-era invite) or a fresh ticket after their
            // re-publish. Join it; a dialing call is now on.
            let answersDial: Bool
            if case .dialing = phase {
                answersDial = true
                phase = .connected(peer: peer)
            } else {
                answersDial = false
            }
            return [.join(ticket: invite.ticket, answersDial: answersDial), .changed]

        case .incoming(let pending):
            guard invite.peer == pending.peer else {
                return [.log("ignored invite from \(invite.peer): already ringing from \(pending.peer)")]
            }
            if invite.isReturn {
                return [.log("ignored return leg from \(invite.peer): no active outgoing call")]
            }
            // A newer invite supersedes the unanswered one: a delayed duplicate
            // must not win after a newer call.
            begin(.incoming(invite), generation: invite.ticket)
            return [.changed]

        case .watching(let peer):
            return [.log("ignored invite from \(invite.peer) while watching \(peer)")]

        case .idle:
            if invite.isReturn {
                return [.log("ignored return leg from \(invite.peer): no active outgoing call")]
            }
            begin(.incoming(invite), generation: invite.ticket)
            return [.ring(peer: invite.peer), .changed]
        }
    }
}

extension CallLifecycle {
    /// Everything that can happen to a call, in the order the host feeds it.
    enum Event {
        /// The user starts an outgoing call.
        case dial(peer: String)
        /// The dial target resolved to its canonical id (name/alias → id).
        case resolve(peer: String)
        /// Our publish succeeded; sets the generation only for the caller's
        /// first publish.
        case published(ticket: String)
        /// An `action=start` invite classified as ours.
        case invite(Invite)
        /// The user answers the incoming invite.
        case answer
        /// The user ends the call (hang up, decline, cancel).
        case hangUp
        /// The peer ended the call (stop envelope or bare `call_stopped`);
        /// nil ticket = a legacy sender with no generation.
        case remoteStop(peer: String, ticket: String?)
        /// A local failure ends the call; the peer is told, or it would sit in
        /// a one-sided call (donpark/idfon: give-up/late-answer flows).
        case fail(String)
        /// End without telling the peer (automation reset).
        case abandon
    }
}
