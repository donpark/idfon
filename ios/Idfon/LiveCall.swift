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
        // `.voiceChat` + speaker, remote audio on its playback bus = the
        // AEC reference; docs/audio-media.md, docs/troubleshooting.md).
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

    /// The call lifecycle (phase, peer, generation, epoch): the single source
    /// of truth — `state` and the rest are views over it (CallLifecycle.swift;
    /// every transition's effects run in `run`).
    private var life = CallLifecycle()
    private(set) var lastError: String?

    var state: State {
        switch life.phase {
        case .idle: return .idle
        case .incoming(let invite): return .incoming(peer: invite.peer)
        case .dialing(let peer): return .calling(peer: peer)
        case .connected(let peer), .watching(let peer): return .inCall(peer: peer)
        }
    }

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

    /// The panel picked an audio route (docs/stereo-calls.md): unmute, and when
    /// the route changes the stream layout (stereo ↔ mono) re-publish the mic
    /// leg and re-send the invite — the peer's handler re-joins on a fresh
    /// invite.
    func setAudioMode(_ mode: CallAudioMode) {
        setAudioEnabled(true)
        guard published, let peer = activePeer else { return }
        let want = ContactAudioProfiles.profile(for: peer) == .pcm24k
            ? 1
            : AudioIO.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republishAudio(channels: want, peer: peer) }
    }

    /// The panel's Stereo toggle: re-publish the mic leg when it changes the
    /// stream layout (silence at the new layout keeps a muted leg simple).
    func setStereo(_ on: Bool) {
        guard published, let peer = activePeer else { return }
        let want = ContactAudioProfiles.profile(for: peer) == .pcm24k
            ? 1
            : AudioIO.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republishAudio(channels: want, peer: peer) }
    }

    /// Re-publish the mic leg at a new channel count and re-invite the peer.
    private func republishAudio(channels: Int, peer: String) async {
        let profile = ContactAudioProfiles.profile(for: peer)
        AudioPusher.shared.retarget(channels: channels)
        await Task.detached(priority: .userInitiated) { media_live_stop() }.value
        let ticket = await ffiString {
            media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate), UInt32(channels))
        }
        guard !ticket.isEmpty else {
            idfonError("idfon live: re-publish failed for \(channels)ch")
            return
        }
        publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
        // No generation change here on purpose: stops must keep naming the
        // call's original ticket (CallLifecycle.generation).
        do {
            try await client.sendText(
                to: peer,
                "IDFON-LIVE/1\naction=start\nticket=\(ticket)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)"
            )
            idfonLog("idfon live: re-published mic leg channels=\(channels)")
        } catch {
            idfonError("idfon live: re-publish invite failed: \(error)")
        }
        notify()
    }

    /// Observed on the main queue whenever state (or error) changed.
    var onState: (() -> Void)?

    private let client = IdfonClient()
    private var published = false
    /// The channel count the mic leg publishes (1 mono, 2 = the 2D mode).
    private var publishedChannels = 1
    private var operation: Task<Void, Never>?

    /// Runs one transition and its effects, then syncs the crash-recovery
    /// keys (`recoverStaleCall`) to the machine.
    private func apply(_ event: CallLifecycle.Event) {
        for effect in life.on(event) { run(effect) }
        persist()
    }

    private func run(_ effect: CallLifecycle.Effect) {
        switch effect {
        case .rejectedBusy:
            CallFeedback.post("A call is already in progress.")
        case .sendStop(let peer, let ticket):
            // Empty ticket = the call never got a generation (ended before its
            // publish landed); an unticketed stop keeps the legacy behavior.
            Task { try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket ?? "", call: false)) }
        case .join(let ticket, _):
            // The peer answered our dial (or re-published a fresh ticket):
            // cue and subscribe non-fatally — a failed subscribe must not tear
            // down a call we are already publishing into.
            CallTonePlayer.shared.start(.answered)
            Task {
                if await !self.subscribe(ticket: ticket) {
                    idfonError("idfon live call: return-leg subscribe failed")
                }
            }
        case .stopMedia:
            operation?.cancel()
            operation = nil
            published = false
            audioEnabled = false
            videoEnabled = false
            HybridVoice.shared.stop()
            AudioPusher.shared.stop()
            Task.detached(priority: .userInitiated) {
                media_live_stop()
                Diag.logCallRecord() // the record folds inside the stop: ship once, here
                media_live_unsubscribe()
            }
        case .endCue:
            CallTonePlayer.shared.start(.ended)
        case .quiet:
            CallTonePlayer.shared.stop()
        case .ring(let peer):
            // The system already rings (a push-first wake): no Bar ringtone and
            // no app-owned audio session alongside it.
            if !CallKitController.shared.isRinging(peer) {
                LiveCallHarness.activateAudioSession()
                CallTonePlayer.shared.start(.ringtone)
            }
        case .changed:
            notify()
        case .remoteEnded(let peer, let ticket):
            // A push-first wake can outlive the machine: the transport truth
            // must end a ringing system call too (#45).
            CallKitController.shared.remoteEnded(peerId: peer, owner: .live, ticket: ticket ?? "")
        case .log(let message):
            idfonLog("idfon live call: \(message)")
        }
    }

    /// Crash recovery reads these; keeping them in step with the machine here
    /// replaces the per-callsite writes that flows used to skip.
    private func persist() {
        let defaults = UserDefaults.standard
        if let peer = life.peer {
            defaults.set(peer, forKey: "idfon.live-call.peer")
        } else {
            defaults.removeObject(forKey: "idfon.live-call.peer")
        }
        if let generation = life.generation {
            defaults.set(generation, forKey: "idfon.live-call.ticket")
        } else {
            defaults.removeObject(forKey: "idfon.live-call.ticket")
        }
    }

    var activePeer: String? { life.peer }

    /// The current call's generation ticket (the dialer's publish ticket),
    /// nil when no call exists — lets a ring push recognize a call the
    /// machines already own (the envelope is queued before the push is sent,
    /// so on a live app it arrives first and the Bar owns the ring, #7).
    var callGeneration: String? { life.generation }

    func clearError() {
        lastError = nil
        notify()
    }

    // MARK: - Caller

    func dial(_ peerRef: String) {
        Automation.mark("live: dial ref=\(peerRef)")
        guard case .idle = life.phase else {
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
        audioEnabled = audioAvailable // this session carries audio from the start
        apply(.dial(peer: peerRef))
        // The cue rides the shared playback bus (AudioIO): start the session
        // first or the tone is dropped before the dial task arms it.
        LiveCallHarness.activateAudioSession()
        CallTonePlayer.shared.start(.ringback)
        let epoch = life.epoch
        operation = Task {
            do {
                // Resolve the ref (name/alias/id) to the canonical peer id: the
                // capability-ticket store (and grants) key on the id, so sending
                // the invite to a display name would skip the holder's gate.
                let peerId = await client.resolvePeerId(peerRef)
                guard case .dialing(let current) = life.phase, current == peerRef || current == peerId else { return }
                apply(.resolve(peer: peerId))
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
                // Stereo (docs/stereo-calls.md): the panel's audio mode picks
                // the stream layout; pcm24k voice-agent calls stay mono —
                // that plane is 20 ms mono PCM frames into ASR/TTS.
                let channels = profile.sampleRate == 48_000 ? AudioIO.captureChannelsForCall() : 1
                guard await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate, channels: channels) else {
                    fail("microphone unavailable")
                    return
                }
                guard life.epoch == epoch, !Task.isCancelled else { return }
                let ticket = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate), UInt32(channels))
                }
                guard life.epoch == epoch, !Task.isCancelled, !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                // Hung up while the publish was in flight: stop the publisher
                // we just started instead of leaking it and ringing the peer.
                guard case .dialing = life.phase else {
                    AudioPusher.shared.stop()
                    Task.detached(priority: .userInitiated) { media_live_stop() }
                    return
                }
                published = true
                publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
                idfonLog("idfon live call: caller audio published profile=\(profile.rawValue)")
                applySendState() // a toggle during `.dialing` may predate the publish
                apply(.published(ticket: ticket))
                // Carry the daemon's current dial address: endpoint-id-only
                // discovery is unreliable for inbound calls to suspended phones.
                let encodedAddr = Data(returnAddr.utf8).base64EncodedString()
                // Tell the agent which half(s) this device runs (hybrid route);
                // nil when the holder runs both, so no context line is sent.
                let inviteContext = SpeechEngines.clientHalfContext(
                    for: peerId, route: CapabilityTickets.voiceRoute(for: peerId))
                // Reset the model history before the call: the session log is the
                // medium, never the model's context (docs/session-context.md).
                _ = try? await client.sendText(to: peerId, "IDFON-SESSION/1\naction=rotate")
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
                    guard life.epoch == epoch, !Task.isCancelled else { return }
                    if case .dialing = life.phase {} else { return } // answered, failed, or hung up
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
        guard case .incoming(let pending) = life.phase else {
            idfonLog("idfon live: answer ignored — not incoming")
            return
        }
        operation?.cancel()
        apply(.answer)
        let epoch = life.epoch
        audioEnabled = audioAvailable
        CallTonePlayer.shared.stop()
        operation = Task {
            do {
                let profile = ContactAudioProfiles.profile(for: pending.peer)
                LiveCallHarness.activateAudioSession()
                // Stereo as on the caller leg (see `dial`); the profile rate
                // must match the publisher below.
                let channels = profile.sampleRate == 48_000 ? AudioIO.captureChannelsForCall() : 1
                var micReady = await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate, channels: channels)
                if !micReady {
                    // The CallKit session may still be activating (the
                    // didActivate handoff): the engine start then fails with
                    // avfaudio 561017449 and the call must not die on it (#51).
                    idfonLog("idfon live: mic start failed; retrying after the session settles")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    micReady = await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate, channels: channels)
                }
                guard micReady else {
                    fail("microphone unavailable")
                    return
                }
                let pendingTicket = pending.ticket
                await join(ticket: pendingTicket)
                guard life.epoch == epoch, !Task.isCancelled else { return }
                // Torn down while subscribing (the subscribe failed and
                // `fail` already ended the call): never publish into a dead
                // session — that would leak a publisher with no call.
                guard case .connected = life.phase else { return }
                // Publish our own mic so audio is two-way, then send the
                // return-leg invite (own ticket) that makes the caller join us.
                let own = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate), UInt32(channels))
                }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                published = true
                publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
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
        guard case .incoming = life.phase else { return }
        CallTonePlayer.shared.stop()
        // The ring brought the shared audio up; a decline must release it.
        AudioIO.shared.stop()
        apply(.hangUp)
    }

    func hangUp() {
        apply(.hangUp)
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
            _ = try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: false))
        }
    }

    // MARK: - Event routing (called by ChatStore on the main actor)

    /// Handles a call-control text from `peerID`.
    func handleControl(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational
        if text == "call_stopped" {
            apply(.remoteStop(peer: peerID, ticket: nil))
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
            apply(.remoteStop(peer: peerID, ticket: invite.ticket.isEmpty ? nil : invite.ticket))
            return
        }
        guard invite.isStart, invite.media == nil else {
            idfonLog("idfon live call: ignored non-audio start from \(peerID)")
            return
        }
        // A leg on our call (return leg / re-publish) comes back as a `.join`
        // effect; a fresh invite rings (or supersedes) via the machine.
        apply(.invite(CallLifecycle.Invite(
            peer: peerID, ticket: invite.ticket, isReturn: invite.isReturn, watchOnly: false)))
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

    private func fail(_ message: String) {
        idfonError("idfon live call failed: \(message)")
        lastError = message
        CallFeedback.post("No live calls from this contact: \(message)")
        // The machine's `.fail` end tells the peer too: a caller that gives up
        // must un-ring a callee who answers late, or they sit in a call alone.
        apply(.fail(message))
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
    /// Speech-unit stream state: one incremental mouth feed per turn
    /// (`docs/voice-agent-loop-contract.md` §2), plus the serial speak chain.
    private var feeders: [String: ChunkFeeder] = [:]
    private var speakChain: Task<Void, Never>?

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

    /// Speak an agent transcript when TTS is on-device. The `final` closes
    /// the unit: whatever the partials did not cover plays as the tail.
    func maybeSpeak(peerId: String, turnId: String, role: String, text: String) {
        guard isActive, speakLocal, role == "agent", !text.isEmpty else { return }
        var feeder = feeders.removeValue(forKey: turnId) ?? ChunkFeeder()
        for chunk in feeder.finish(text) { speakQueued(chunk) }
    }

    /// Speech-unit `partial` (loop contract §2): the cumulative snapshot of
    /// the agent's spoken text so far. Chunks start playback as they close —
    /// first audio at the first sentence instead of at reply end.
    func streamPartial(turnId: String, text: String) {
        guard isActive, speakLocal, !text.isEmpty else { return }
        var feeder = feeders[turnId] ?? ChunkFeeder()
        let chunks = feeder.feed(text)
        feeders[turnId] = feeder
        for chunk in chunks { speakQueued(chunk) }
    }

    /// One utterance at a time through the mouth (each engine is
    /// single-utterance), chained in arrival order.
    private func speakQueued(_ text: String) {
        let prior = speakChain
        speakChain = Task { @MainActor in
            await prior?.value
            await self.tts.speak(text)
        }
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
