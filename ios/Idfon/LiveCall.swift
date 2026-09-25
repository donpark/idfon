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
        DaemonPaths.dataDir.appendingPathComponent("last-call.wav").path
    }

    /// Configure the audio session before any daemon audio starts.
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try? session.setActive(true)
        try? session.overrideOutputAudioPort(.none)
    }

    /// Dial a peer and stream the bundled WAV. Blocks until the callee hangs
    /// up or `seconds` elapses — run off the main actor.
    static func dial(peer: String, seconds: UInt64, client: DaemonClient) async throws {
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
    static func armAutoAnswer(waitSeconds: UInt64, captureSeconds: UInt64, client: DaemonClient) async throws -> String {
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

    private let client = DaemonClient()
    private var pendingInvite: (peer: String, ticket: String)?
    private var published = false
    private var operationGeneration = 0
    private var operation: Task<Void, Never>?

    var activePeer: String? {
        switch state {
        case .incoming(let peer), .calling(let peer), .inCall(let peer): return peer
        case .idle: return nil
        }
    }

    func clearError() {
        lastError = nil
        notify()
    }

    // MARK: - Caller

    func dial(_ peerRef: String) {
        guard case .idle = state else { return }
        operation?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        state = .calling(peer: peerRef)
        UserDefaults.standard.set(peerRef, forKey: "idfon.live-call.peer")
        audioEnabled = audioAvailable // this session carries audio from the start
        notify()
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
                NSLog("idfon live call: caller audio published profile=\(profile.rawValue)")
                applySendState() // a toggle during `.calling` may predate the publish
                UserDefaults.standard.set(peerId, forKey: "idfon.live-call.peer")
                // Carry the daemon's current dial address: endpoint-id-only
                // discovery is unreliable for inbound calls to suspended phones.
                let encodedAddr = Data(returnAddr.utf8).base64EncodedString()
                try await client.sendText(
                    to: peerId,
                    "IDFON-LIVE/1\naction=start\nticket=\(ticket)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)\nreturn_addr=\(encodedAddr)"
                )
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    func answer() {
        guard case .incoming(let peer) = state, let pending = pendingInvite else { return }
        operation?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        pendingInvite = nil
        state = .inCall(peer: peer)
        audioEnabled = audioAvailable
        notify()
        operation = Task {
            do {
                let profile = ContactAudioProfiles.profile(for: pending.peer)
                LiveCallHarness.activateAudioSession()
                guard await AudioPusher.shared.startForCall(sampleRate: profile.sampleRate) else {
                    fail("microphone unavailable")
                    return
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
                NSLog("idfon live call: callee audio published profile=\(profile.rawValue)")
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
        Task { try? await client.sendText(to: peer, "call_stopped") }
    }

    func hangUp() {
        terminate(local: true)
    }

    func recoverStaleCall() {
        guard let peer = UserDefaults.standard.string(forKey: "idfon.live-call.peer") else { return }
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_live_unsubscribe()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: "", call: false))
        }
    }

    // MARK: - Event routing (called by ChatStore on the main actor)

    /// Handles a call-control text from `peerID`.
    func handleControl(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational
        if text == "call_stopped" {
            if case .idle = state { return }
            if activePeer == peerID { terminate(local: false) }
        }
    }

    /// Handles an IDFON-LIVE/1 envelope. Consumes audio invites/stops;
    /// video envelopes are ignored here (VideoCall owns them) — but a stop
    /// ends our call too since the GUI sends one envelope for both.
    func handleEnvelope(peer peerID: String, _ text: String) {
        guard let invite = LiveInvite.parse(text) else {
            NSLog("idfon live call: unparsed envelope from \(peerID)")
            return
        }
        NSLog("idfon live call: envelope peer=\(peerID) state=\(String(describing: state)) start=\(invite.isStart) stop=\(invite.isStop) return=\(invite.isReturn) audio=\(invite.media == nil) ticket=\(!invite.ticket.isEmpty)")
        if invite.isStop {
            if case .idle = state { return }
            if activePeer == peerID { terminate(local: false) }
            return
        }
        guard invite.isStart, invite.media == nil, !invite.ticket.isEmpty else {
            NSLog("idfon live call: ignored non-audio or incomplete start from \(peerID)")
            return
        }
        // Return leg: the peer we called answered and is publishing its mic.
        // Subscribe non-fatally (a failed subscribe must not tear down a call
        // we are already publishing into); `.calling` → `.inCall`. Another
        // peer's invite while busy is ignored (no steal).
        switch state {
        case .calling, .inCall:
            guard activePeer == peerID else {
                NSLog("idfon live call: return leg peer mismatch active=\(activePeer ?? "nil") from=\(peerID)")
                return
            }
            NSLog("idfon live call: return leg received from \(peerID)")
            Task {
                if await !subscribe(ticket: invite.ticket) {
                    NSLog("idfon live call: return-leg subscribe failed")
                }
                if case .calling = state { state = .inCall(peer: peerID); notify() }
            }
            return
        case .incoming, .idle:
            if invite.isReturn {
                NSLog("idfon live call: ignored return leg without an active outgoing call from \(peerID)")
                return
            }
        }
        // A newer invite from the same peer supersedes an unanswered one.
        // This prevents a delayed duplicate from winning after a newer call.
        if case .incoming(let pendingPeer) = state {
            guard pendingPeer == peerID else { return }
            pendingInvite = (peerID, invite.ticket)
            NSLog("idfon live: replaced pending invite from \(peerID)")
            notify()
            return
        }
        guard case .idle = state else { return } // video-call invites route to VideoCall
        pendingInvite = (peerID, invite.ticket)
        UserDefaults.standard.set(peerID, forKey: "idfon.live-call.peer")
        state = .incoming(peer: peerID)
        notify()
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
        NSLog("idfon live call: subscription start result=\(result)")
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
        if local {
            Task { try? await client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: "", call: false)) }
        }
        operation?.cancel()
        operation = nil
        operationGeneration += 1
        published = false
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        pendingInvite = nil
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
        NSLog("idfon live call failed: \(message)")
        lastError = message
        terminate(local: false)
    }

    private func notify() {
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
