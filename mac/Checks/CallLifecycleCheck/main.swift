// Runnable check for `CallLifecycle` (not part of the build targets). Guards
// the call-lifecycle contract: one exit path that always tells the peer, an
// immutable generation that re-publishes cannot drift, and stops correlated by
// that generation (donpark/idfon#60 + the "caller stayed connected after the
// callee hung up" bug class).
//
//   swiftc -o /tmp/calllifecyclecheck \
//     mac/Sources/Idfon/CallLifecycle.swift mac/Checks/CallLifecycleCheck/main.swift
//   /tmp/calllifecyclecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

func effects(_ life: inout CallLifecycle, _ event: CallLifecycle.Event) -> [CallLifecycle.Effect] {
    life.on(event)
}

/// The caller flow: dial → publish → peer's leg arrives → connected.
func connectedCall() -> CallLifecycle {
    var life = CallLifecycle()
    _ = effects(&life, .dial(peer: "peer"))
    _ = effects(&life, .published(ticket: "T1"))
    let leg = effects(&life, .invite(.init(peer: "peer", ticket: "T2", isReturn: true, watchOnly: false)))
    check(leg.contains(.join(ticket: "T2", answersDial: true)), "return leg is joined and answers the dial")
    check(life.phase == .connected(peer: "peer"), "dialing call is connected once the leg arrives")
    check(life.generation == "T1", "the generation is the caller's publish ticket")
    return life
}

// 1. Callee hangs up (ticketed stop): the caller disconnects and stops media.
do {
    var life = connectedCall()
    let fx = effects(&life, .remoteStop(peer: "peer", ticket: "T1"))
    check(life.phase == .idle, "callee hang-up disconnects the caller")
    check(fx.contains(.stopMedia), "remote hang-up stops media")
    check(fx.contains(.endCue), "a connected call ends with the end cue")
    check(!fx.contains(where: { if case .sendStop = $0 { return true }; return false }),
          "remote hang-up sends no stop back")
}

// 2. THE reported bug: a re-publish must not move the generation, so the
// peer's hang-up still names the call.
do {
    var life = connectedCall()
    _ = effects(&life, .published(ticket: "T1-repub")) // stereo/route re-publish
    check(life.generation == "T1", "re-publish does not move the generation")
    let fx = effects(&life, .remoteStop(peer: "peer", ticket: "T1"))
    check(life.phase == .idle, "hang-up after our re-publish still disconnects")
    check(!fx.contains(where: { if case .log = $0 { return true }; return false }),
          "nothing is dropped or explained away")
}
do {
    // The mirrored case: the callee re-published, so its hang-up must still
    // carry the generation the caller knows.
    var life = CallLifecycle()
    let ring = effects(&life, .invite(.init(peer: "caller", ticket: "T1", isReturn: false, watchOnly: false)))
    check(ring.contains(.ring(peer: "caller")), "a fresh invite rings")
    _ = effects(&life, .answer)
    _ = effects(&life, .published(ticket: "T2"))       // the callee's own publish
    _ = effects(&life, .published(ticket: "T2-repub")) // and its re-publish
    let fx = effects(&life, .hangUp)
    check(fx.contains(.sendStop(peer: "caller", ticket: "T1")),
          "callee hang-up names the generation, not its last publish ticket")
}

// 3. A stop naming an older call is ignored (donpark/idfon#60).
do {
    var life = connectedCall()
    let fx = effects(&life, .remoteStop(peer: "peer", ticket: "T-old"))
    check(life.phase == .connected(peer: "peer"), "a stop naming an older call is ignored")
    check(fx.contains(where: { if case .log = $0 { return true }; return false }),
          "an ignored stop is explained, never silent")
}

// 4. Legacy bare `call_stopped`: the peer can vouch, a stranger cannot.
do {
    var life = connectedCall()
    _ = effects(&life, .remoteStop(peer: "stranger", ticket: nil))
    check(life.phase == .connected(peer: "peer"), "bare stop from another peer is ignored")
    _ = effects(&life, .remoteStop(peer: "peer", ticket: nil))
    check(life.phase == .idle, "bare stop from the call peer ends the call")
}

// 5. Give-up tells the peer (the late-answerer must not sit in a call).
do {
    var life = CallLifecycle()
    _ = effects(&life, .dial(peer: "peer"))
    _ = effects(&life, .published(ticket: "T1"))
    let fx = effects(&life, .fail("no answer (peer unreachable)"))
    check(life.phase == .idle, "a failed dial ends")
    check(fx.contains(.sendStop(peer: "peer", ticket: "T1")), "a failed dial tells the peer")
}

// 6. Decline/hang-up on a ring names the invite ticket (the pending invite is
// the state's data — the #51 wedge cannot exist).
do {
    var life = CallLifecycle()
    _ = effects(&life, .invite(.init(peer: "caller", ticket: "T1", isReturn: false, watchOnly: false)))
    let fx = effects(&life, .hangUp)
    check(life.phase == .idle, "decline ends the ring")
    check(fx.contains(.sendStop(peer: "caller", ticket: "T1")), "decline names the invite's ticket")
    check(fx.contains(.quiet), "an unconnected ring goes quiet")
}

// 7. Caller cancels while we ring: remote stop ends it without a stop back.
do {
    var life = CallLifecycle()
    _ = effects(&life, .invite(.init(peer: "caller", ticket: "T1", isReturn: false, watchOnly: false)))
    let fx = effects(&life, .remoteStop(peer: "caller", ticket: "T1"))
    check(life.phase == .idle, "caller cancel ends the ring")
    check(!fx.contains(where: { if case .sendStop = $0 { return true }; return false }),
          "a remote-ended ring sends nothing back")
}

// 8. Watch-only share: answer joins without publishing and ends with a
// ticketed stop (legacy bare `call_stopped` no longer needed).
do {
    var life = CallLifecycle()
    _ = effects(&life, .invite(.init(peer: "sharer", ticket: "T1", isReturn: false, watchOnly: true)))
    let fx = effects(&life, .answer)
    check(life.phase == .watching(peer: "sharer"), "answering a share opens a watch session")
    check(life.generation == "T1", "the share's invite ticket is the generation")
    _ = fx
    let end = effects(&life, .hangUp)
    check(end.contains(.sendStop(peer: "sharer", ticket: "T1")), "stopping a watch names the invite ticket")
    check(end.contains(.quiet), "a watch session ends quietly")
}

// 9. Busy guards: no stealing, no second call.
do {
    var life = connectedCall()
    let fx = effects(&life, .dial(peer: "other"))
    check(fx.contains(.rejectedBusy), "dialing while busy is refused")
    check(life.phase == .connected(peer: "peer"), "the running call survives the refused dial")
    let intruder = effects(&life, .invite(.init(peer: "other", ticket: "T9", isReturn: false, watchOnly: false)))
    check(life.phase == .connected(peer: "peer"), "another peer's invite never steals the call")
    check(!intruder.contains(where: { if case .join = $0 { return true }; return false }),
          "the intruding invite is not joined")
}

// 10. A ticketed stop names its call even when the sender's ref differs (a
// push or envelope can arrive under another identity).
do {
    var life = connectedCall()
    let fx = effects(&life, .remoteStop(peer: "peer-alias", ticket: "T1"))
    check(life.phase == .idle, "the generation vouches for the stop regardless of the ref")
    _ = fx
}

// 11. Return legs with no active dial are ignored; answers with no ring too.
do {
    var life = CallLifecycle()
    let fx = effects(&life, .invite(.init(peer: "peer", ticket: "T2", isReturn: true, watchOnly: false)))
    check(life.phase == .idle, "a return leg without an outgoing call is ignored")
    check(fx.contains(where: { if case .log = $0 { return true }; return false }), "and is explained")
    let answered = effects(&life, .answer)
    check(answered.contains(where: { if case .log = $0 { return true }; return false }),
          "answering with no incoming call is explained, never silent")
}

// 12. The epoch voids in-flight work on every open and every end.
do {
    var life = CallLifecycle()
    let start = life.epoch
    _ = effects(&life, .dial(peer: "peer"))
    check(life.epoch != start, "dialing moves the epoch")
    let dialing = life.epoch
    _ = effects(&life, .answer)
    check(life.epoch == dialing, "answering nothing keeps the epoch")
    _ = effects(&life, .abandon)
    check(life.epoch != dialing, "ending moves the epoch")
    check(life.phase == .idle, "abandon ends without a stop")
}

// 13. Supersede: a newer invite from the same peer replaces the unanswered one.
do {
    var life = CallLifecycle()
    _ = effects(&life, .invite(.init(peer: "caller", ticket: "T1", isReturn: false, watchOnly: false)))
    let fx = effects(&life, .invite(.init(peer: "caller", ticket: "T2", isReturn: false, watchOnly: false)))
    check(life.generation == "T2", "a newer invite supersedes the unanswered one")
    check(!fx.contains(.ring(peer: "caller")), "a supersede does not re-ring")
    let end = effects(&life, .hangUp)
    check(end.contains(.sendStop(peer: "caller", ticket: "T2")), "decline names the newest invite")
}

print("ALL OK")
