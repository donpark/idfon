import AVFAudio
import CallKit

/// CallKit owner for `call_kit` channels (docs/callkit-integration.md, P1).
///
/// CallKit **mirrors** the call state machines (`LiveCall`/`VideoCall`) — they
/// stay the source of truth; this type owns only what the system must see:
/// the `CXProvider` call lifecycle, the `AVAudioSession` handoff, and mute
/// sync. One call at a time (the machines enforce it). Rules carried from the
/// plan's verified bug list:
///
/// * every system report happens in the same turn as the state change that
///   caused it — never after an await (ghost-call flash);
/// * a call UUID is never reported back as ended when the system itself ended
///   it (`endedBySystem`, the unknownCallUUID race);
/// * a failed report falls the channel back to the Bar instead of silencing it.
@MainActor
final class CallKitController: NSObject, CXProviderDelegate {
    static let shared = CallKitController()

    /// Which machine a mirrored call belongs to — `LiveCall` and `VideoCall`
    /// notify independently and must not end each other's system call.
    enum Owner { case live, video }

    /// The lifecycle phase the machines report on every state change.
    enum Phase { case incoming, calling, inCall, idle }

    struct Call {
        let uuid: UUID
        let peerId: String
        let owner: Owner
        let video: Bool
        let outgoing: Bool
        var connectingReported = false
        var connectedReported = false
        /// The system itself ended the call (CXEndCallAction, provider reset):
        /// the mirror must not report the end back.
        var endedBySystem = false
        /// The system answered the call (CXAnswerCallAction from the unified
        /// UX): the mirror must not request the answer back.
        var answeredBySystem = false
        /// An in-app answer was already mirrored to the system.
        var answerMirrored = false
    }

    /// The call CallKit is presenting, if any.
    private(set) var current: Call?

    private var provider: CXProvider!
    private let callController = CXCallController()
    /// The machine's dial body, run by `didPerform CXStartCallAction`.
    private var startBody: (() -> Void)?
    /// Set when the user answers before the invite envelope has landed (the
    /// push-first wake): the answer runs as soon as the envelope arrives.
    private var pendingAnswer: Owner?
    private var pendingAnswerWork: DispatchWorkItem?
    /// Last mute state mirrored; echoes of a system `CXSetMutedCallAction` are
    /// dropped (the delegate records the state before touching the machine).
    private var lastMuted = false

    private override init() {
        super.init()
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Incoming

    /// Whether a system call for this peer is up (ringing or connected): the
    /// single truth behind "no double presentation" — the Bar ring and its
    /// in-app ringtone stay out exactly when the system is already on it.
    func isRinging(_ peerId: String) -> Bool {
        guard let call = current, !call.outgoing else { return false }
        return call.peerId == peerId
    }

    /// Push-first ring (P2): the payload's `call_uuid` is the caller's
    /// `CallUUID.from(invite ticket)`, so the envelope dedupes onto this call
    /// when it lands. The only path that reports a ring — one that arrived
    /// over iroh never gets a system bar (#7). Reported before anything else —
    /// a VoIP push that does not result in a reported call is grounds for app
    /// termination.
    /// `endImmediately` serves `mustReport` pushes for a bar-mode channel:
    /// report first, end once the report completes (never before — ending a
    /// call whose registration has not completed fails the report, #58).
    func presentPush(callUUID: String, callerId: String, hasVideo: Bool, endImmediately: Bool = false) {
        guard !callerId.isEmpty, !callUUID.isEmpty else { return }
        let uuid = UUID(uuidString: callUUID) ?? CallUUID.from(ticket: callUUID)
        if let existing = current, !existing.outgoing {
            // Redelivery of the call already ringing: it is reported — keep
            // it. Match on the call UUID, never on the peer: a *newer* call
            // from the same peer (a redial) must supersede below, or its
            // mustReport push ends in no reported call and PushKit stops
            // delivering VoIP pushes to a suspended app entirely.
            if existing.uuid == uuid { return }
            // Never steal a call this device answered.
            if answeredLocally(existing) {
                idfonLog("idfon callkit: push ring ignored — busy")
                return
            }
            // A newer ring supersedes a stale unanswered one (#59): a dead
            // ring must not block the real call.
            idfonLog("idfon callkit: push ring supersedes \(existing.uuid.uuidString)")
            endIncomingCall(existing, reason: .declinedElsewhere)
        }
        let update = callUpdate(
            name: IncomingCallRouter.shared.name(for: callerId), hasVideo: hasVideo)
        current = Call(
            uuid: uuid, peerId: callerId,
            owner: hasVideo ? .video : .live,
            video: hasVideo, outgoing: false)
        AudioIO.shared.callKitWillStart()
        idfonLog("idfon callkit: reporting push ring \(uuid.uuidString) from \(callerId)")
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let error else {
                if endImmediately {
                    Task { @MainActor in self?.endReportedIfUnanswered(uuid: uuid) }
                }
                return
            }
            DispatchQueue.main.async {
                idfonError("idfon callkit: push report failed: \(error.localizedDescription)")
                self?.abandonToBar(peerId: callerId)
            }
        }
        refreshName(uuid: uuid, peerId: callerId)
    }

    /// `mustReport` compliance: end the just-reported call once its
    /// registration completes (the report-then-end pattern, #58).
    private func endReportedIfUnanswered(uuid: UUID) {
        guard let call = current, call.uuid == uuid, !answeredLocally(call) else { return }
        endIncomingCall(call, reason: .remoteEnded)
    }

    /// Placeholder until the peer records are known: never a raw id hash on
    /// the call screen.
    private static let unknownCaller = "Idfon caller"

    private func callUpdate(name: String?, hasVideo: Bool) -> CXCallUpdate {
        let display = name ?? Self.unknownCaller
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: display)
        update.localizedCallerName = display
        update.hasVideo = hasVideo
        return update
    }

    /// The report must not wait for the daemon (the same-turn rule), so the
    /// name comes from the persisted peer cache; once the live records are
    /// known the system call UI is updated in place.
    private func refreshName(uuid: UUID, peerId: String) {
        Task { @MainActor in
            await IncomingCallRouter.shared.refreshModes()
            guard self.current?.uuid == uuid,
                  let name = IncomingCallRouter.shared.name(for: peerId) else { return }
            let update = self.callUpdate(name: name, hasVideo: self.current?.video ?? false)
            self.provider.reportCall(with: uuid, updated: update)
        }
    }

    /// A `cancel` push (the caller hung up before answer, or the ring is
    /// over): end in one turn. Returns whether a matching call was ended.
    @discardableResult
    func cancelFromPush(callUUID: String) -> Bool {
        guard let call = current, !call.outgoing,
              call.uuid.uuidString.caseInsensitiveCompare(callUUID) == .orderedSame
        else { return false }
        // A ring-over (the caller connected on another device) must dismiss
        // only unanswered rings — never a call this device answered (#46).
        if answeredLocally(call) { return false }
        idfonLog("idfon callkit: push cancel call=\(callUUID)")
        endIncomingCall(call, reason: .remoteEnded)
        return true
    }

    /// True when this device answered the call: media up, or an answer
    /// waiting for its invite envelope.
    private func answeredLocally(_ call: Call) -> Bool {
        if pendingAnswer != nil { return true }
        switch call.owner {
        case .live: if case .inCall = LiveCall.shared.state { return true }
        case .video: if VideoCall.shared.state == .inCall { return true }
        }
        return false
    }

    /// The peer hung up at the transport level (`call_stopped` or a stop
    /// envelope): the de-escalation must not depend on the cancel push
    /// arriving (#45). Only the machine that owns the ringing call may end it
    /// (`owner`), so an audio stop cannot dismiss a video ring and vice versa.
    /// A non-empty ticket names the call generation — the ring UUID derives
    /// from that ticket — so a stop for an older call is ignored (#60). An
    /// empty ticket is a legacy sender: match by peer.
    func remoteEnded(peerId: String, owner: Owner, ticket: String = "") {
        guard let call = current, !call.outgoing, call.owner == owner,
              call.peerId == peerId else { return }
        if !ticket.isEmpty, CallUUID.from(ticket: ticket) != call.uuid {
            idfonLog("idfon callkit: stop for an older call ignored peer=\(peerId)")
            return
        }
        idfonLog("idfon callkit: remote ended call=\(call.uuid.uuidString)")
        endIncomingCall(call, reason: .remoteEnded)
    }

    /// Ends a not-yet-connected incoming call in one turn (the graceful
    /// de-escalation pattern).
    private func endIncomingCall(_ call: Call, reason: CXCallEndedReason) {
        current = nil
        pendingAnswer = nil
        pendingAnswerWork?.cancel()
        AudioIO.shared.callKitDidEnd()
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        // Decline whichever machine holds the ringing call (holder dispatch,
        // like the answer action): `owner` can disagree with the envelope's
        // media line, and a wrong-owner decline left the ring alive.
        if VideoCall.shared.state == .incoming {
            VideoCall.shared.decline()
        } else if case .incoming = LiveCall.shared.state {
            LiveCall.shared.decline()
        }
    }

    /// Called after the machines consumed an invite envelope: a pending answer
    /// (push-first wake) completes now that the machine can answer. Answer the
    /// machine that actually holds the invite — the owner armed at answer time
    /// can disagree with the envelope's media line (#51 E2E).
    func envelopeArrived() {
        guard pendingAnswer != nil else { return }
        pendingAnswer = nil
        pendingAnswerWork?.cancel()
        if VideoCall.shared.state == .incoming {
            VideoCall.shared.answer()
        } else if case .incoming = LiveCall.shared.state {
            LiveCall.shared.answer()
        }
        // The deferred accept completes here too — same landing as an
        // immediate accept (the accept handler owns the navigation).
        if let ref = current?.peerId, !ref.isEmpty {
            NotificationCenter.default.post(
                name: .init("idfon.callkit.answered"), object: nil, userInfo: ["ref": ref])
        }
    }

    /// The user answered while the invite was still in flight.
    private func armPendingAnswer(_ owner: Owner) {
        pendingAnswer = owner
        pendingAnswerWork?.cancel()
        // The invite is on its way (the wake just happened); if it never
        // lands, do not hold the system call open on silence.
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.pendingAnswer == owner else { return }
                self.pendingAnswer = nil
                idfonError("idfon callkit: answered but the invite never arrived")
                if let call = self.current, !call.endedBySystem {
                    self.current = nil
                    AudioIO.shared.callKitDidEnd()
                    self.provider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed)
                }
            }
        }
        pendingAnswerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    // MARK: - Outgoing

    /// Wraps a machine's dial in the system call UI: `body` runs when the
    /// system performs `CXStartCallAction`, and the audio engine waits for
    /// `didActivate` (AudioIO defers while CallKit owns the session).
    func startOutgoing(peerId: String, video: Bool, body: @escaping () -> Void) {
        let uuid = UUID()
        current = Call(
            uuid: uuid, peerId: peerId,
            owner: video ? .video : .live,
            video: video, outgoing: true)
        startBody = body
        AudioIO.shared.callKitWillStart()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: peerId))
        callController.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                idfonError("idfon callkit: start-call transaction failed: \(error.localizedDescription)")
                guard let self else { return }
                // CallKit must never break calling: dial on the Bar path.
                let body = self.startBody
                self.startBody = nil
                self.current = nil
                AudioIO.shared.callKitDidEnd()
                IncomingCallRouter.shared.forceBarFallback(peerId)
                body?()
            }
        }
    }

    // MARK: - Mirroring (called from the machines' notify())

    /// Diffs against the presented call, so repeated notifications are no-ops.
    func mirror(owner: Owner, phase: Phase) {
        switch phase {
        case .incoming:
            break // the ring was reported when it arrived (presentPush)
        case .calling:
            guard var call = current, call.owner == owner, call.outgoing,
                  !call.connectingReported else { return }
            call.connectingReported = true
            current = call
            provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
        case .inCall:
            guard var call = current, call.owner == owner else { return }
            guard call.outgoing else {
                // Answered in-app while the system call rings: request the
                // matching CXAnswerCallAction so the unified UX follows —
                // without it the system UI rings forever on an answered call.
                guard !call.answeredBySystem, !call.answerMirrored else { return }
                call.answerMirrored = true
                current = call
                callController.request(CXTransaction(action: CXAnswerCallAction(call: call.uuid))) { error in
                    if let error {
                        idfonError("idfon callkit: answer mirror failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            guard !call.connectedReported else { return }
            if !call.connectingReported {
                call.connectingReported = true
                provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
            }
            call.connectedReported = true
            current = call
            provider.reportOutgoingCall(with: call.uuid, connectedAt: Date())
        case .idle:
            guard let call = current, call.owner == owner else { return }
            current = nil
            AudioIO.shared.callKitDidEnd()
            guard !call.endedBySystem else { return }
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded)
        }
    }

    /// Mute changed in-app (Bar): mirror to the system UI.
    func mutedChanged(_ muted: Bool) {
        guard let call = current, muted != lastMuted else { return }
        lastMuted = muted
        let action = CXSetMutedCallAction(call: call.uuid, muted: muted)
        callController.request(CXTransaction(action: action)) { error in
            if let error {
                idfonError("idfon callkit: mute transaction failed: \(error.localizedDescription)")
            }
        }
    }

    /// App is going away mid-call: report the end so the system's in-call
    /// banner cannot outlive the process (the stuck-banner failure mode).
    func appWillTerminate() {
        guard let call = current else { return }
        current = nil
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed)
    }

    // MARK: - CXProviderDelegate (system queue → main actor)

    // The SDK dispatches call actions through `provider(_:perform:)` overloads
    // typed per action (Apple docs, CXProviderDelegate "Handling Call
    // Actions"): a single `perform action: CXAction`/`didPerform` method
    // matches none of the optional requirements and is silently never called
    // (the E2E where the system Accept/Reject did nothing in-app).
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        dispatch(action)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        dispatch(action)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        dispatch(action)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        dispatch(action)
    }

    /// Settle the action on a deadline: CXAction times out in ~5s and an
    /// unsettled answer hangs the system UI ("froze when I pressed answer",
    /// #61 — the same main-actor starvation as the push completion, #55).
    /// End always completes (the user's hang-up wins), anything else fails
    /// so CallKit rolls back and the call stays answerable.
    private nonisolated func dispatch(_ action: CXAction) {
        let gate = ActionOnce(action)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { gate.timeout() }
        Task { @MainActor in self.perform(action, gate: gate) }
    }

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.reset() }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in AudioIO.shared.callKitDidActivate() }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }

    private func perform(_ action: CXAction, gate: ActionOnce) {
        switch action {
        case is CXStartCallAction:
            let body = startBody
            startBody = nil
            body?() // the machine's dial: publish + invite
            gate.fulfill()
        case is CXAnswerCallAction:
            if var call = current {
                call.answeredBySystem = true // the system answered; don't mirror back
                current = call
            }
            // Answer whichever machine holds the invite: the push's has_video
            // (owner) can disagree with the envelope's media line, and a
            // wrong-owner answer used to vanish silently (#51 E2E).
            idfonLog("idfon callkit: answer action owner=\(String(describing: current?.owner)) live=\(LiveCall.shared.state) video=\(VideoCall.shared.state)")
            if VideoCall.shared.state == .incoming {
                VideoCall.shared.answer()
            } else if case .incoming = LiveCall.shared.state {
                LiveCall.shared.answer()
            } else if current != nil {
                armPendingAnswer(current?.owner ?? .live) // push-first: invite in flight
            } else {
                gate.fail()
                return
            }
            // Accepting lands on the caller's chat (docs/callkit-integration.md
            // #7): hide the incoming bar, show the in-progress overlay, and
            // navigate — the accept handler owns the navigation.
            if let ref = current?.peerId, !ref.isEmpty {
                NotificationCenter.default.post(
                    name: .init("idfon.callkit.answered"), object: nil, userInfo: ["ref": ref])
            }
            gate.fulfill()
        case is CXEndCallAction:
            // The user's end must reset the push-first state even when the
            // machines never saw the call (the invite never arrived): nothing
            // else clears `current`/`pendingAnswer`, and the UI then hangs
            // until the 20s pending-answer guard fires.
            pendingAnswer = nil
            pendingAnswerWork?.cancel()
            if var call = current {
                call.endedBySystem = true // the end is the system's; don't report back
                current = call
                // Act on whichever machine holds the call — the answer
                // action's dispatch rule: `owner` (the push's has_video) can
                // disagree with the envelope's media line, and a wrong-owner
                // end declined an idle machine while the ring lived on
                // ("reject does nothing").
                if VideoCall.shared.state == .incoming {
                    VideoCall.shared.decline()
                } else if case .incoming = LiveCall.shared.state {
                    LiveCall.shared.decline()
                } else if call.owner == .video {
                    VideoCall.shared.hangUp()
                } else {
                    LiveCall.shared.hangUp()
                }
                // Clear in this turn regardless: the mirror can miss a call
                // whose `owner` disagrees with the holder, and a stale
                // `current` blocks every later ring.
                current = nil
                AudioIO.shared.callKitDidEnd()
            }
            gate.fulfill()
        case let muted as CXSetMutedCallAction:
            lastMuted = muted.isMuted // echo guard: the mirror must not re-request
            switch current?.owner {
            case .live: LiveCall.shared.setAudioEnabled(!muted.isMuted)
            case .video: VideoCall.shared.setAudioEnabled(!muted.isMuted)
            case nil: break
            }
            gate.fulfill()
        default:
            gate.fulfill()
        }
    }

    /// Settles a CXAction exactly once: the main-actor path and the deadline
    /// fallback race for it (double-settling a CXAction is undefined).
    /// @unchecked Sendable: state is NSLock-guarded.
    private final class ActionOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var action: CXAction?
        init(_ action: CXAction) { self.action = action }
        func fulfill() { settle { $0.fulfill() } }
        func fail() { settle { $0.fail() } }
        /// Deadline: end always completes, anything else fails.
        func timeout() {
            settle { action in
                if action is CXEndCallAction { action.fulfill() } else { action.fail() }
            }
        }
        private func settle(_ body: (CXAction) -> Void) {
            lock.lock()
            let action = self.action
            self.action = nil
            lock.unlock()
            if let action { body(action) }
        }
    }

    private func reset() {
        guard let call = current else { return }
        current = nil
        startBody = nil
        AudioIO.shared.callKitDidEnd()
        // The system dropped every call: tear the machine down and tell the peer.
        switch call.owner {
        case .live: LiveCall.shared.hangUp()
        case .video: VideoCall.shared.hangUp()
        }
    }

    /// CallKit refused the ring: drop this channel back to the Bar and ring
    /// there — an unavailable presenter must never silence a channel.
    private func abandonToBar(peerId: String) {
        current = nil
        startBody = nil
        AudioIO.shared.callKitDidEnd()
        IncomingCallRouter.shared.forceBarFallback(peerId)
        CallTonePlayer.shared.start(.ringtone)
        NotificationCenter.default.post(name: .init("idfon.callkit.barFallback"), object: nil)
    }
}
