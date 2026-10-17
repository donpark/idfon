import Foundation
import AVFAudio

/// Live-call harness over Idfon's media/session methods (test/automation path).
///
/// Swift owns the Apple audio session; Idfon owns authorization, signaling, and
/// current iroh-live transport. It streams a bundled WAV file and the callee
/// records to a file; the real audio call state machine is below.
enum LiveCallHarness {
    /// File the dialer streams (bundled 3s 440Hz sine).
    static var bundledWavPath: String {
        Bundle.main.path(forResource: "hello", ofType: "wav") ?? ""
    }

    /// Where the callee's recording lands (sandbox, daemon-readable since
    /// the daemon runs in-process).
    static var recordingPath: String {
        IdfonPaths.dataDir.appendingPathComponent("last-call.wav").path
    }

    /// Configure the audio session before any daemon audio starts.
    static func activateAudioSession() {
        // The single audio owner configures the session (`liveCall` profile:
        // `.default` + speaker, AEC from `setVoiceProcessingEnabled`;
        // docs/troubleshooting.md, "audio too quiet").
        AudioIO.shared.start(profile: .liveCall)
    }

    /// Dial a peer and stream the bundled WAV. Blocks until the callee hangs
    /// up or `seconds` elapses — run off the main actor.
    static func dial(peer: String, seconds: UInt64, client: IdfonClient) async throws {
        activateAudioSession()
        _ = try await client.request(method: "media.live.dial", params: [
            "to": AnyEncodable(peer),
            "file": AnyEncodable(bundledWavPath),
            "seconds": AnyEncodable(Int(seconds)),
        ])
    }

    /// Arm auto-answer: blocks until someone dials, records the call to the
    /// sandbox recording path. Run in a long-lived task; `wait` caps how
    /// long the daemon listens per attempt.
    static func armAutoAnswer(waitSeconds: UInt64, captureSeconds: UInt64, client: IdfonClient) async throws -> String {
        activateAudioSession()
        let result = try await client.request(method: "media.live.answer", params: [
            "wait": AnyEncodable(Int(waitSeconds)),
            "seconds": AnyEncodable(Int(captureSeconds)),
            "out": AnyEncodable(recordingPath),
        ])
        return result?["out"]?.stringValue ?? recordingPath
    }
}

/// Live audio-call state machine (ported from mac/Sources/Idfon/Calls.swift):
/// Swift captures microphone PCM and the Idfon media bridge publishes it over
/// current iroh-live before the caller sends an invite; the callee subscribes
/// (decoded playback), publishes its own mic, and sends an audio return-leg
/// invite carrying its ticket — so audio is two-way and the caller leaves
/// `.calling` (parity with VideoCall). `call_started` is still sent as
/// informational parity. Mirrors native/src/core.ts's video flow; the native
/// audio `live_answer` branch is still subscribe-only (known interop gap).
///
/// Audio invites carry no `media` line; `media=video-call` invites belong to
/// `VideoCall`, which ignores audio invites here — the two machines are
/// disjoint and cannot both be non-idle.
@MainActor
final class LiveCall {
    static let shared = LiveCall()

    enum State: Equatable {
        case idle
        case incoming(peer: String)
        case calling(peer: String)
        case inCall(peer: String)
    }

    private(set) var state: State = .idle
    private(set) var lastError: String?

    // MARK: - Outgoing stream set (docs/ui-design-notes.md §3 State 3)

    /// What the session was published with — immutable for the call's life.
    /// LiveCall always publishes audio only, so it never carries video.
    let audioAvailable = true
    let videoAvailable = false
    /// Whether each stream is currently being *sent* (mute/unmute, camera
    /// on/off); never track attach/detach. Reset when the call ends.
    private(set) var audioEnabled = false
    private(set) var videoEnabled = false

    /// Mute/unmute outgoing audio: disabled sends silence, capture stays open.
    /// A toggle that lands before `dial` has published is recorded and pushed
    /// once the session exists.
    func setAudioEnabled(_ enabled: Bool) {
        guard audioAvailable else { return }
        audioEnabled = enabled
        applySendState()
        CallKitController.shared.mutedChanged(!enabled)
        notify()
    }

    /// No camera track exists on an audio call; the Bar hides the button.
    func setVideoEnabled(_ enabled: Bool) {
        guard videoAvailable else { return }
        videoEnabled = enabled
        applySendState()
        notify()
    }

    /// Observed on the main queue whenever state (or error) changed.
    var onState: (() -> Void)?

    private let client = IdfonClient()
    private var pendingInvite: (peer: String, ticket: String)?
    /// The call generation's identity: the dialer's publish ticket, known to
    /// both sides (the caller generated it, the callee received it in the
    /// start invite). Stops carry it so an out-of-order stop from an older
    /// call cannot terminate this one (#60).
    private var callTicket: String?
    private var published = false
    private var operationGeneration = 0
    private var operation: Task<Void, Never>?

    var activePeer: String? {
        switch state {
        case .incoming(let peer), .calling(let peer), .inCall(let peer): return peer
        case .idle: return nil
        }
    }

    /// Records the call generation's identity (persisted so a crash can name
    /// it in `recoverStaleCall`).
    private func setCallTicket(_ ticket: String) {
        callTicket = ticket
        UserDefaults.standard.set(ticket, forKey: "idfon.live-call.ticket")
    }

    private func clearCallTicket() {
        callTicket = nil
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.ticket")
    }

    /// Whether a stop envelope names this call (#60). The rule lives in the
    /// tested pure seam; an empty ticket keeps the old terminate behavior.
    private func stopNamesThisCall(_ ticket: String) -> Bool {
        CallStopCorrelation.names(ticket, current: callTicket)
    }

    func clearError() {
        lastError = nil
        notify()
    }

    // MARK: - Caller

    func dial(_ peerRef: String) {
        Automation.mark("live: dial ref=\(peerRef)")
        guard case .idle = state else {
            CallFeedback.post("A call is already in progress.")
            return
        }
        // `call_kit` channels dial through the system call UI — CallKit owns
        // the whole call lifecycle, both directions (docs/callkit-integration.md).
        if IncomingCallRouter.shared.ownsPresentation(for: peerRef) {
            CallKitController.shared.startOutgoing(peerId: peerRef, video: false) { [weak self] in
                self?.dialNow(peerRef)
            }
        } else {
            dialNow(peerRef)
        }
    }

    private func dialNow(_ peerRef: String) {
        operation?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        state = .calling(peer: peerRef)
        UserDefaults.standard.set(peerRef, forKey: "idfon.live-call.peer")
        audioEnabled = audioAvailable // this session carries audio from the start
        notify()
        // The cue rides the shared playback bus (AudioIO): start the session
        // first or the tone is dropped before the dial task arms it.
        LiveCallHarness.activateAudioSession()
        CallTonePlayer.shared.start(.ringback)
        operation = Task {
            do {
                // Resolve the ref (name/alias/id) to the canonical peer id: the
                // capability-ticket store (and grants) key on the id, so sending
                // the invite to a display name would skip the holder's gate.
                let peerId = await client.resolvePeerId(peerRef)
                guard case .calling(let current) = state, current == peerRef || current == peerId else { return }
                state = .calling(peer: peerId)
                // Registry entry (parity with core.ts live_start).
                let identity = (try? await client.status())?.1 ?? "default"
                let returnAddr = try await client.localEndpointAddr()
                let peerBytes = Array(peerId.utf8.map { AnyEncodable(Int($0)) })
                _ = try? await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_audio"),
                    "mode": AnyEncodable("record"),
                ])
                let profile = ContactAudioProfiles.profile(for: peerId)
                LiveCallHarness.activateAudioSession()
                guard await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate) else {
                    fail("microphone unavailable")
                    return
                }
                guard operationGeneration == generation, !Task.isCancelled else { return }
                let ticket = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate))
                }
                guard operationGeneration == generation, !Task.isCancelled, !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                // Hung up while the publish was in flight: stop the publisher
                // we just started instead of leaking it and ringing the peer.
                guard case .calling = state else {
                    AudioPusher.shared.stop()
                    Task.detached(priority: .userInitiated) { media_live_stop() }
                    return
                }
                published = true
                idfonLog("idfon live call: caller audio published profile=\(profile.rawValue)")
                applySendState() // a toggle during `.calling` may predate the publish
                UserDefaults.standard.set(peerId, forKey: "idfon.live-call.peer")
                setCallTicket(ticket)
                // Carry the daemon's current dial address: endpoint-id-only
                // discovery is unreliable for inbound calls to suspended phones.
                let encodedAddr = Data(returnAddr.utf8).base64EncodedString()
                // Tell the agent which half(s) this device runs (hybrid route);
                // nil when the holder runs both, so no context line is sent.
                let inviteContext = SpeechEngines.clientHalfContext(
                    for: peerId, route: CapabilityTickets.voiceRoute(for: peerId))
                // Reset the model history before the call: the session log is the
                // medium, never the model's context (docs/session-context.md).
                try? await client.sendText(to: peerId, "IDFON-SESSION/1\naction=rotate")
                let inviteOperation = try await client.sendText(
                    to: peerId,
                    "IDFON-LIVE/1\naction=start\nticket=\(ticket)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)\nreturn_addr=\(encodedAddr)\(ContactVoiceSelection.inviteLines(for: peerId, context: inviteContext))"
                )
                // Wake the peer's devices on a `call_kit` channel (P2): ring
                // via the edge once the invite is queued. The call_uuid is the
                // invite ticket's, so the callee's push report and the
                // envelope land on the same system call.
                if IncomingCallRouter.shared.ownsPresentation(for: peerId) {
                    PushWake.shared.ring(
                        peer: peerId, callUUID: CallUUID.from(ticket: ticket).uuidString,
                        hasVideo: false)
                }
                // Dial watchdog: the invite was accepted for delivery, but if the
                // return leg never lands (peer offline, relay flap, network
                // transition), do not hang in .calling forever. Delivery is
                // watched too (message.send only queues): "no answer" must never
                // stand in for an invite that never left this device.
                var delivered = false
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard operationGeneration == generation, !Task.isCancelled else { return }
                    if case .calling = state {} else { return } // answered, failed, or hung up
                    if !delivered, let inviteOperation {
                        let status = (try? await client.operationStatus(inviteOperation)) ?? nil
                        if status == "Delivered" {
                            delivered = true
                        } else if ["Failed", "Expired", "Cancelled"].contains(status ?? "") {
                            fail("invite delivery failed (network unreachable)")
                            return
                        }
                    }
                }
                fail(delivered ? "no answer (peer unreachable)" : "invite not delivered (network unreachable)")
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    func answer() {
        Automation.mark("live: answer")
        guard case .incoming(let peer) = state, let pending = pendingInvite else { return }
        operation?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        pendingInvite = nil
        setCallTicket(pending.ticket)
        state = .inCall(peer: peer)
        audioEnabled = audioAvailable
        notify()
        CallTonePlayer.shared.stop()
        operation = Task {
            do {
                let profile = ContactAudioProfiles.profile(for: pending.peer)
                LiveCallHarness.activateAudioSession()
                guard await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate) else {
                    // The CallKit session may still be activating (the
                    // didActivate handoff): the engine start then fails with
                    // avfaudio 561017449 and the call must not die on it (#51).
                    idfonLog("idfon live: mic start failed; retrying after the session settles")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate) else {
                        fail("microphone unavailable")
                        return
                    }
                }
                let pendingTicket = pending.ticket
                await join(ticket: pendingTicket)
                guard operationGeneration == generation, !Task.isCancelled else { return }
                // Torn down while subscribing (the subscribe failed and
                // `fail` already ended the call): never publish into a dead
                // session — that would leak a publisher with no call.
                guard case .inCall = state else { return }
                // Publish our own mic so audio is two-way, then send the
                // return-leg invite (own ticket) that makes the caller join us.
                let own = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate))
                }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                published = true
                idfonLog("idfon live call: callee audio published profile=\(profile.rawValue)")
                applySendState() // the mic toggle drives a real published session now
                // Audio invite: no media line (audio is the default).
                try await client.sendText(
                    to: pending.peer,
                    "IDFON-LIVE/1\naction=start\nticket=\(own)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)"
                )
                // Informational parity with core.ts's video answer branch.
                try await client.sendText(to: pending.peer, "call_started")
            } catch {
                fail("Answer failed: \(error.localizedDescription)")
            }
        }
    }

    func decline() {
        guard case .incoming(let peer) = state else { return }
        state = .idle
        notify()
        CallTonePlayer.shared.stop()
        // The ring brought the shared audio up; a decline must release it.
        AudioIO.shared.stop()
        let ticket = callTicket ?? ""
        Task { try? await client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: false)) }
        clearCallTicket()
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
    }

    func hangUp() {
        terminate(local: true)
    }

    func recoverStaleCall() {
        guard let peer = UserDefaults.standard.string(forKey: "idfon.live-call.peer") else { return }
        // The crash left the call generation behind; name it so a live call
        // that took its place is not ended by this recovery stop (#60).
        let ticket = UserDefaults.standard.string(forKey: "idfon.live-call.ticket") ?? ""
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.ticket")
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_live_unsubscribe()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: false))
        }
    }

    // MARK: - Event routing (called by ChatStore on the main actor)

    /// Handles a call-control text from `peerID`.
    func handleControl(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational
        if text == "call_stopped" {
            if case .idle = state {
                // A push-first wake can outlive the machine: the transport
                // truth must end a ringing system call too (#45).
                CallKitController.shared.remoteEnded(peerId: peerID, owner: .live)
                return
            }
            if activePeer == peerID { terminate(local: false) }
        }
    }

    /// Handles an IDFON-LIVE/1 envelope. Consumes audio invites/stops;
    /// video envelopes are ignored here (VideoCall owns them) — but a stop
    /// ends our call too since the GUI sends one envelope for both.
    func handleEnvelope(peer peerID: String, _ text: String) {
        guard let invite = LiveInvite.parse(text) else {
            idfonLog("idfon live call: unparsed envelope from \(peerID)")
            return
        }
        idfonLog("idfon live call: envelope peer=\(peerID) state=\(String(describing: state)) start=\(invite.isStart) stop=\(invite.isStop) return=\(invite.isReturn) audio=\(invite.media == nil) ticket=\(!invite.ticket.isEmpty)")
        if invite.isStop {
            if case .idle = state {
                // A push-first wake can outlive the machine: the transport
                // truth must end a ringing system call too (#45), correlated
                // to the call the stop names (#60).
                CallKitController.shared.remoteEnded(peerId: peerID, owner: .live, ticket: invite.ticket)
                return
            }
            guard activePeer == peerID else { return }
            guard stopNamesThisCall(invite.ticket) else {
                idfonLog("idfon live call: ignored stop for an older call peer=\(peerID)")
                return
            }
            terminate(local: false)
            return
        }
        guard invite.isStart, invite.media == nil, !invite.ticket.isEmpty else {
            idfonLog("idfon live call: ignored non-audio or incomplete start from \(peerID)")
            return
        }
        // Return leg: the peer we called answered and is publishing its mic.
        // Subscribe non-fatally (a failed subscribe must not tear down a call
        // we are already publishing into); `.calling` → `.inCall`. Another
        // peer's invite while busy is ignored (no steal).
        switch state {
        case .calling, .inCall:
            guard activePeer == peerID else {
                idfonLog("idfon live call: return leg peer mismatch active=\(activePeer ?? "nil") from=\(peerID)")
                return
            }
            idfonLog("idfon live call: return leg received from \(peerID)")
            CallTonePlayer.shared.start(.answered)
            Task {
                if await !subscribe(ticket: invite.ticket) {
                    idfonError("idfon live call: return-leg subscribe failed")
                }
                if case .calling = state { state = .inCall(peer: peerID); notify() }
            }
            return
        case .incoming, .idle:
            if invite.isReturn {
                idfonLog("idfon live call: ignored return leg without an active outgoing call from \(peerID)")
                return
            }
        }
        // A newer invite from the same peer supersedes an unanswered one.
        // This prevents a delayed duplicate from winning after a newer call.
        if case .incoming(let pendingPeer) = state {
            guard pendingPeer == peerID else { return }
            pendingInvite = (peerID, invite.ticket)
            setCallTicket(invite.ticket)
            idfonLog("idfon live: replaced pending invite from \(peerID)")
            notify()
            return
        }
        guard case .idle = state else { return } // video-call invites route to VideoCall
        pendingInvite = (peerID, invite.ticket)
        UserDefaults.standard.set(peerID, forKey: "idfon.live-call.peer")
        setCallTicket(invite.ticket)
        state = .incoming(peer: peerID)
        notify()
        // The system already rings (a push-first wake): no Bar ringtone and
        // no app-owned audio session alongside it.
        if !CallKitController.shared.isRinging(peerID) {
            LiveCallHarness.activateAudioSession()
            CallTonePlayer.shared.start(.ringtone)
        }
    }

    // MARK: - Internals

    /// Pushes the current send state to the published session (no-op while the
    /// publish is still in flight or already stopped).
    private func applySendState() {
        guard published else { return }
        let audio: UInt8 = audioEnabled ? 1 : 0
        Task.detached(priority: .userInitiated) { _ = media_live_set_audio_enabled(audio) }
    }

    /// Subscribes to a peer ticket without tearing the call down on failure.
    private func subscribe(ticket: String) async -> Bool {
        let result = await Task.detached(priority: .userInitiated) {
            media_live_subscribe(ticket)
        }.value
        idfonLog("idfon live call: subscription start result=\(result)")
        return result == 0
    }

    private func join(ticket: String) async {
        guard await subscribe(ticket: ticket) else {
            fail("live subscribe failed")
            return
        }
    }

    private func terminate(local: Bool) {
        guard let peer = activePeer else { return }
        HybridVoice.shared.stop()
        if local {
            let ticket = callTicket ?? ""
            Task { try? await client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: false)) }
        }
        operation?.cancel()
        operation = nil
        operationGeneration += 1
        published = false
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        clearCallTicket()
        pendingInvite = nil
        // End cue only when a connected call ends; an unconnected ring
        // (decline/cancel) goes quiet (#15).
        if case .inCall = state { CallTonePlayer.shared.start(.ended) } else { CallTonePlayer.shared.stop() }
        audioEnabled = false
        videoEnabled = false
        AudioPusher.shared.stop()
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_live_unsubscribe()
        }
        state = .idle
        notify()
    }

    private func fail(_ message: String) {
        idfonError("idfon live call failed: \(message)")
        lastError = message
        CallFeedback.post("No live calls from this contact: \(message)")
        terminate(local: false)
    }

    private func notify() {
        // CallKit mirrors the machine in the same turn
        // (docs/callkit-integration.md); a no-op when no system call is up.
        let phase: CallKitController.Phase
        switch state {
        case .idle: phase = .idle
        case .incoming: phase = .incoming
        case .calling: phase = .calling
        case .inCall: phase = .inCall
        }
        if phase == .inCall { PushWake.shared.callConnected() }
        if phase == .idle { PushWake.shared.cancelRing() }
        CallKitController.shared.mirror(owner: .live, phase: phase)
        onState?()
    }

    private func ffiString(_ body: @escaping () -> UnsafeMutablePointer<CChar>?) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let ptr = body() else { return "" }
            defer { rust_free_string(ptr) }
            return String(cString: ptr)
        }.value
    }
}

/// Hybrid server-cascade call: the holder runs the live session but the caller
/// supplies one half on-device (per the signed `voice_route.stt`/`tts`).
///
/// - `stt = client`: run on-device ASR and send the transcript to the holder as
///   an `IDFON-LIVE/1 action=text` control; the holder runs the agent + TTS.
/// - `tts = client`: speak the holder's agent transcripts with on-device TTS
///   instead of playing return audio.
@MainActor
final class HybridVoice {
    static let shared = HybridVoice()

    private let client = IdfonClient()
    private let segmenter = VoicePromptSegmenter()
    private var asr: (any AsrEngine)?
    private var tts: TtsEngine = SpeechEngines.tts
    private(set) var isActive = false
    private var peerId: String?
    private var speakLocal = false

    func start(peerRef: String, route: VoiceRoute) {
        Automation.mark("hybrid: start ref=\(peerRef)")
        guard !isActive, route.isHybrid else { return }
        isActive = true
        peerId = peerRef
        speakLocal = route.ttsSide == .client
        // Per-contact on-device engine, else the app default.
        if speakLocal {
            tts = SpeechEngines.makeTts(
                ContactOnDeviceEngines.tts(for: peerRef).flatMap(TtsBackend.init(rawValue:)) ?? SpeechEngines.backend)
        }
        LiveCall.shared.dial(peerRef)
        if route.sttSide == .client {
            Task { @MainActor in await self.startLocalAsr(peerRef: peerRef) }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        peerId = nil
        speakLocal = false
        segmenter.stop()
        asr?.stop()
        asr = nil
    }

    /// Speak an agent transcript when TTS is on-device.
    func maybeSpeak(peerId: String, role: String, text: String) {
        guard isActive, speakLocal, role == "agent", !text.isEmpty else { return }
        Task { @MainActor in await tts.speak(text) }
    }

    private func startLocalAsr(peerRef: String) async {
        let peers = (try? await client.peers()) ?? []
        guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else { return }
        peerId = peer.id
        segmenter.onPartial = { _ in }
        segmenter.onCommit = { [weak self] text in self?.sendTranscript(text) }
        segmenter.start()
        // Per-contact on-device recognizer, else the app default.
        let engine = SpeechEngines.makeAsr(
            ContactOnDeviceEngines.asr(for: peer.id).flatMap(AsrBackend.init(rawValue:)) ?? SpeechEngines.asrBackend)
        asr = engine
        do {
            try await engine?.start(
                enableVoiceProcessing: true,
                onText: { [weak self] text, isFinal in
                    DispatchQueue.main.async { self?.segmenter.handle(text, isFinal: isFinal) }
                },
                onError: { message in Automation.mark("hybrid: asr error \(message)") }
            )
        } catch {
            Automation.mark("hybrid: asr start failed \(error.localizedDescription)")
        }
        asr?.resume()
    }

    private func sendTranscript(_ text: String) {
        guard let peerId, !text.isEmpty else { return }
        let payload = Data(text.utf8).base64EncodedString()
        let control = "IDFON-LIVE/1\naction=text\ntext_b64=\(payload)"
        Automation.mark("hybrid: caller text=\(text)")
        Task { @MainActor in
            do { try await client.sendText(to: peerId, control) }
            catch { Automation.mark("hybrid: text send failed \(error.localizedDescription)") }
        }
    }
}
