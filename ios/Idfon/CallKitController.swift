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

    /// Push-first ring (P2): the payload's `call_uuid` is the caller's
    /// `CallUUID.from(invite ticket)`, so the envelope dedupes onto this call
    /// when it lands. Reported before anything else — a VoIP push that does
    /// not result in a reported call is grounds for app termination.
    func presentPush(callUUID: String, callerId: String, hasVideo: Bool) {
        guard !callerId.isEmpty, !callUUID.isEmpty else { return }
        guard current == nil else {
            idfonLog("idfon callkit: push ring ignored — a call is already up")
            return
        }
        let uuid = UUID(uuidString: callUUID) ?? CallUUID.from(ticket: callUUID)
        let update = callUpdate(
            name: IncomingCallRouter.shared.name(for: callerId), hasVideo: hasVideo)
        current = Call(
            uuid: uuid, peerId: callerId,
            owner: hasVideo ? .video : .live,
            video: hasVideo, outgoing: false)
        AudioIO.shared.callKitWillStart()
        idfonLog("idfon callkit: reporting push ring \(uuid.uuidString) from \(callerId)")
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                idfonError("idfon callkit: push report failed: \(error.localizedDescription)")
                self?.abandonToBar(peerId: callerId)
            }
        }
        refreshName(uuid: uuid, peerId: callerId)
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

    /// A `cancel` push (the caller hung up before answer): end in one turn.
    /// Returns whether a matching call was ended.
    @discardableResult
    func cancelFromPush(callUUID: String) -> Bool {
        guard let call = current, !call.outgoing,
              call.uuid.uuidString.caseInsensitiveCompare(callUUID) == .orderedSame
        else { return false }
        idfonLog("idfon callkit: push cancel call=\(callUUID)")
        current = nil
        pendingAnswer = nil
        pendingAnswerWork?.cancel()
        AudioIO.shared.callKitDidEnd()
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded)
        switch call.owner {
        case .live:
            if case .incoming = LiveCall.shared.state { LiveCall.shared.decline() }
        case .video:
            if VideoCall.shared.state == .incoming { VideoCall.shared.decline() }
        }
        return true
    }

    /// Called after the machines consumed an invite envelope: a pending answer
    /// (push-first wake) completes now that the machine can answer.
    func envelopeArrived() {
        guard let owner = pendingAnswer else { return }
        pendingAnswer = nil
        pendingAnswerWork?.cancel()
        switch owner {
        case .live:
            if case .incoming = LiveCall.shared.state { LiveCall.shared.answer() }
        case .video:
            if VideoCall.shared.state == .incoming { VideoCall.shared.answer() }
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

    /// Reports a ringing call for an accepted incoming invite. A second invite
    /// from the same peer (supersede/redelivery) keeps the ring already up —
    /// the machines hold the newest ticket, the UUID is presentation identity.
    func presentIncoming(peerId: String, name: String?, invite: LiveInvite) {
        if let call = current, call.peerId == peerId, !call.outgoing { return }
        guard current == nil else {
            idfonLog("idfon callkit: invite ignored — a call is already up")
            return
        }
        let uuid = CallUUID.from(ticket: invite.ticket)
        let update = callUpdate(name: name, hasVideo: invite.isCall)
        current = Call(
            uuid: uuid, peerId: peerId,
            owner: invite.isCall ? .video : .live,
            video: invite.isCall, outgoing: false)
        AudioIO.shared.callKitWillStart()
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                idfonError("idfon callkit: incoming report failed: \(error.localizedDescription)")
                self?.abandonToBar(peerId: peerId)
            }
        }
        refreshName(uuid: uuid, peerId: peerId)
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
            break // presentIncoming already reported the ring
        case .calling:
            guard var call = current, call.owner == owner, call.outgoing,
                  !call.connectingReported else { return }
            call.connectingReported = true
            current = call
            provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
        case .inCall:
            guard var call = current, call.owner == owner, call.outgoing,
                  !call.connectedReported else { return }
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

    nonisolated func provider(_ provider: CXProvider, didPerform action: CXAction) {
        Task { @MainActor in self.perform(action) }
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

    private func perform(_ action: CXAction) {
        switch action {
        case let start as CXStartCallAction:
            let body = startBody
            startBody = nil
            body?() // the machine's dial: publish + invite
            start.fulfill()
        case let answer as CXAnswerCallAction:
            switch current?.owner {
            case .live:
                if case .incoming = LiveCall.shared.state { LiveCall.shared.answer() }
                else { armPendingAnswer(.live) } // push-first: invite in flight
            case .video:
                if VideoCall.shared.state == .incoming { VideoCall.shared.answer() }
                else { armPendingAnswer(.video) }
            case nil: answer.fail(); return
            }
            answer.fulfill()
        case let end as CXEndCallAction:
            if var call = current {
                call.endedBySystem = true // the end is the system's; don't report back
                current = call
                switch call.owner {
                case .live:
                    if case .incoming = LiveCall.shared.state { LiveCall.shared.decline() }
                    else { LiveCall.shared.hangUp() }
                case .video:
                    if VideoCall.shared.state == .incoming { VideoCall.shared.decline() }
                    else { VideoCall.shared.hangUp() }
                }
            }
            end.fulfill()
        case let muted as CXSetMutedCallAction:
            lastMuted = muted.isMuted // echo guard: the mirror must not re-request
            switch current?.owner {
            case .live: LiveCall.shared.setAudioEnabled(!muted.isMuted)
            case .video: VideoCall.shared.setAudioEnabled(!muted.isMuted)
            case nil: break
            }
            muted.fulfill()
        default:
            action.fulfill()
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
