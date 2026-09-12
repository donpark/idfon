import Foundation
import AVFAudio

/// Live-call harness over the daemon's media methods (test/automation path).
///
/// The daemon owns this media pipeline (cpal file source + iroh-live); the
/// shell only triggers dial/answer and manages the audio session. It streams
/// a bundled WAV file and the callee records to a file — the real audio call
/// state machine is the `LiveCall` class below.
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
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
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
/// the caller publishes its microphone through the c-ffi (cpal capture inside
/// the dylib) and sends an invite carrying its ticket; the callee subscribes
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

    func dial(_ peerId: String) {
        guard case .idle = state else { return }
        state = .calling(peer: peerId)
        audioEnabled = audioAvailable // this session carries audio from the start
        notify()
        Task {
            do {
                // Registry entry (parity with core.ts live_start).
                let identity = (try? await client.status())?.1 ?? "default"
                let peerBytes = Array(peerId.utf8.map { AnyEncodable(Int($0)) })
                _ = try? await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_audio"),
                    "mode": AnyEncodable("record"),
                ])
                LiveCallHarness.activateAudioSession()
                let ticket = await ffiString { media_live_start(1, 0) } // audio only
                guard !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                // Hung up while the publish was in flight: stop the publisher
                // we just started instead of leaking it and ringing the peer.
                guard case .calling = state else {
                    Task.detached(priority: .userInitiated) { media_live_stop() }
                    return
                }
                published = true
                applySendState() // a toggle during `.calling` may predate the publish
                // Audio invite: no media line (audio is the default).
                try await client.sendText(to: peerId, "IDFON-LIVE/1\naction=start\nticket=\(ticket)")
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    func answer() {
        guard case .incoming(let peer) = state, let pending = pendingInvite else { return }
        state = .inCall(peer: peer)
        audioEnabled = audioAvailable
        notify()
        Task {
            do {
                LiveCallHarness.activateAudioSession()
                await join(ticket: pending.ticket)
                // Torn down while subscribing (the subscribe failed and
                // `fail` already ended the call): never publish into a dead
                // session — that would leak a publisher with no call.
                guard case .inCall = state else { return }
                // Publish our own mic so audio is two-way, then send the
                // return-leg invite (own ticket) that makes the caller join us.
                let own = await ffiString { media_live_start(1, 0) } // audio only
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                published = true
                applySendState() // the mic toggle drives a real published session now
                // Audio invite: no media line (audio is the default).
                try await client.sendText(to: pending.peer, "IDFON-LIVE/1\naction=start\nticket=\(own)")
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
        guard let invite = LiveInvite.parse(text) else { return }
        if invite.isStop {
            if case .idle = state { return }
            if activePeer == peerID { terminate(local: false) }
            return
        }
        guard invite.isStart, invite.media == nil, !invite.ticket.isEmpty else { return }
        // Return leg: the peer we called answered and is publishing its mic.
        // Subscribe non-fatally (a failed subscribe must not tear down a call
        // we are already publishing into); `.calling` → `.inCall`. Another
        // peer's invite while busy is ignored (no steal).
        switch state {
        case .calling, .inCall:
            guard activePeer == peerID else { return }
            Task {
                if await !subscribe(ticket: invite.ticket) {
                    NSLog("idfon live call: return-leg subscribe failed")
                }
                if case .calling = state { state = .inCall(peer: peerID); notify() }
            }
            return
        case .incoming, .idle:
            break
        }
        guard case .idle = state else { return } // video-call invites route to VideoCall
        pendingInvite = (peerID, invite.ticket)
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
        await Task.detached(priority: .userInitiated) { () -> Bool in
            media_live_subscribe(ticket) == 1
        }.value
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
            if published {
                Task { try? await client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: "", call: false)) }
            } else {
                Task { try? await client.sendText(to: peer, "call_stopped") }
            }
        }
        published = false
        pendingInvite = nil
        audioEnabled = false
        videoEnabled = false
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
