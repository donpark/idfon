import AppKit
import Foundation
import CIdfon

/// A screen that renders call state. Both call machines fan out to every
/// registered observer, so the Bar and the chat header can coexist without
/// clobbering each other's callback.
@MainActor
protocol CallStateObserver: AnyObject {
    func callStateDidChange()
}

/// Parsed IDFON-LIVE/1 invite envelope (native/src/core.ts parseLiveInvite).
/// Shape: "IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=<ticket>"
struct LiveInvite {
    let isStart: Bool
    let isStop: Bool
    /// media line value: nil = audio, "video" = one-way file share,
    /// "video-call" = live camera call.
    let media: String?
    let ticket: String

    static func parse(_ text: String) -> LiveInvite? {
        guard text.hasPrefix("IDFON-LIVE/1\n") else { return nil }
        let body = text.dropFirst("IDFON-LIVE/1\n".count)
        guard body.hasPrefix("action=") else { return nil }
        var fields: [String: String] = [:]
        var lastKey: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let eq = line.firstIndex(of: "=") {
                lastKey = String(line[..<eq])
                fields[lastKey!] = String(line[line.index(after: eq)...])
            } else if let key = lastKey, !line.isEmpty {
                fields[key]? += "\n" + line
            }
        }
        guard let action = fields["action"] else { return nil }
        return LiveInvite(
            isStart: action == "start",
            isStop: action == "stop",
            media: fields["media"],
            ticket: fields["ticket"] ?? ""
        )
    }

    static func build(action: String, ticket: String, call: Bool) -> String {
        let media = call ? "video-call" : "video"
        return "IDFON-LIVE/1\naction=\(action)\nmedia=\(media)\nticket=\(ticket)"
    }
}

/// Live audio-call state machine: the caller publishes their microphone
/// through the c-ffi (cpal capture inside the dylib) and sends an invite
/// carrying its ticket; the callee subscribes (decoded playback), publishes
/// its own mic, and sends an audio return-leg invite carrying its ticket —
/// so audio is two-way and the caller leaves `.calling` (parity with
/// VideoCall). `call_started` is still sent as informational parity. Mirrors
/// native/src/core.ts's video flow; the native audio `live_answer` branch is
/// still subscribe-only (known interop gap).
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

    /// Fired on the main queue when an incoming invite arrives (GUI parity:
    /// banner + auto-open regardless of open chat).
    var onIncoming: ((_ peerID: String) -> Void)?

    private let stateObservers = NSHashTable<AnyObject>.weakObjects()

    /// Registers a screen to be told when call state changes; held weakly.
    func addStateObserver(_ observer: CallStateObserver) {
        stateObservers.add(observer)
    }

    private let client = DaemonClient()

    // MARK: - Caller

    func dial(_ peerId: String) {
        guard case .idle = state else { return }
        let profile = ContactAudioProfiles.profile(for: peerId)
        AudioMeter.shared.configureForCall(sampleRate: profile.sampleRate)
        operation?.cancel()
        operationGeneration += 1
        audioEnabled = true // this session carries audio from the start
        UserDefaults.standard.set(peerId, forKey: "idfon.live-call.peer")
        state = .calling(peer: peerId)
        notify()
        let generation = operationGeneration
        operation = Task {
            do {
                // Registry entry (parity with core.ts live_start).
                let identity = (try? await client.identityId()) ?? "default"
                let peerBytes = Array(peerId.utf8.map { AnyEncodable(Int($0)) })
                _ = try? await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_audio"),
                    "mode": AnyEncodable("record"),
                ])
                AudioMeter.shared.pushToEncoder = true
                guard await AudioMeter.shared.startForCall(sampleRate: profile.sampleRate) else {
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
                // Hung up while the publish was in flight: stop it rather than
                // leaking it and ringing the peer.
                guard case .calling = state else {
                    Task.detached(priority: .userInitiated) { media_live_stop() }
                    return
                }
                published = true
                applySendState()
                try await client.sendText(
                    to: peerId,
                    "IDFON-LIVE/1\naction=start\nticket=\(ticket)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)"
                )
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    func answer() {
        guard case .incoming(let peer) = state, let pending = pendingInvite else { return }
        let profile = ContactAudioProfiles.profile(for: pending.peer)
        AudioMeter.shared.configureForCall(sampleRate: profile.sampleRate)
        audioEnabled = true
        operation?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        pendingInvite = nil
        state = .inCall(peer: peer)
        notify()
        operation = Task {
            do {
                let pendingTicket = pending.ticket
                await join(ticket: pendingTicket)
                guard operationGeneration == generation, !Task.isCancelled else { return }
                // Torn down while subscribing (`fail` already ended the call):
                // never publish into a dead session.
                guard case .inCall = state else { return }
                // Publish our own mic so audio is two-way, then send the
                // return-leg invite (own ticket) that makes the caller join us.
                AudioMeter.shared.pushToEncoder = true
                guard await AudioMeter.shared.startForCall(sampleRate: profile.sampleRate) else {
                    fail("microphone unavailable")
                    return
                }
                let own = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate))
                }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "live start failed" : err)
                    return
                }
                published = true
                applySendState()
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
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
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
        // A newer invite from the same peer supersedes an unanswered one.
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
        onIncoming?(peerID)
    }

    // MARK: - Send gating (§3 State 3)

    /// This machine carries audio only; video is never available here.
    let audioAvailable = true
    let videoAvailable = false
    /// Whether each stream is currently *sent* (send/no-send gating, never
    /// track attach/detach).
    private(set) var audioEnabled = false
    private(set) var videoEnabled = false

    /// Mute/unmute outgoing audio: disabled sends silence, capture stays open.
    func setAudioEnabled(_ enabled: Bool) {
        guard audioAvailable else { return }
        audioEnabled = enabled
        applySendState()
        notify()
    }

    /// No-op on this machine: there is no video track to gate.
    func setVideoEnabled(_ enabled: Bool) {
        guard videoAvailable else { return }
        videoEnabled = enabled
        applySendState()
        notify()
    }

    /// Pushes the current send state to the published session (no-op while the
    /// publish is still in flight, or after it stopped).
    private func applySendState() {
        guard published else { return }
        let audio: UInt8 = audioEnabled ? 1 : 0
        Task.detached(priority: .userInitiated) {
            _ = media_live_set_audio_enabled(audio)
        }
    }

    // MARK: - Internals

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

    /// A process crash cannot send the normal stop envelope. On the next
    /// launch, close the persisted session at the peer before accepting calls.
    func recoverStaleCall() {
        guard let peer = UserDefaults.standard.string(forKey: "idfon.live-call.peer") else { return }
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_live_unsubscribe()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? await self.client.sendText(to: peer, "call_stopped")
        }
    }

    /// Subscribes to a peer ticket without tearing the call down on failure.
    private func subscribe(ticket: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            media_live_subscribe(ticket) == 0
        }.value
    }

    private func join(ticket: String) async {
        guard await subscribe(ticket: ticket) else {
            fail("live subscribe failed")
            return
        }
    }

    private func terminate(local: Bool) {
        NSLog("idfon live terminate local=\(local) state=\(state) peer=\(activePeer ?? "nil") published=\(published)")
        guard let peer = activePeer else { return }
        if local {
            if published {
                Task { try? await client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: "", call: false)) }
            } else {
                Task { try? await client.sendText(to: peer, "call_stopped") }
            }
        }
        operation?.cancel()
        operation = nil
        operationGeneration += 1
        published = false
        UserDefaults.standard.removeObject(forKey: "idfon.live-call.peer")
        audioEnabled = false
        videoEnabled = false
        pendingInvite = nil
        AudioMeter.shared.stop()
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
        for case let observer as CallStateObserver in stateObservers.allObjects {
            observer.callStateDidChange()
        }
    }

    private func ffiString(_ body: @escaping () -> UnsafeMutablePointer<CChar>?) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let ptr = body() else { return "" }
            defer { rust_free_string(ptr) }
            return String(cString: ptr)
        }.value
    }
}

/// 1:1 video-call state machine, mirroring the tested flow in
/// native/src/core.ts (video_call_start / live_answer video-call branch /
/// return-leg branch). The dialer publishes mic+camera and sends an invite
/// carrying its ticket; the callee answers by watching + hearing the caller
/// while publishing its own broadcast and sending its own invite back; the
/// caller receives that return leg and joins it. One-way video-file invites
/// (media=video) open a watch-only session instead.
///
/// Swift owns camera/audio capture and call UI lifecycle; the Idfon media
/// bridge publishes/subscribes current MoQ tracks and writes decoded frames
/// for the native view. Signaling stays on the daemon socket.
@MainActor
final class VideoCall {
    static let shared = VideoCall()

    enum State: Equatable { case idle, calling, incoming, watching, inCall }

    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// Decoded peer frames (~10fps), main queue.
    var onFrame: ((NSImage?) -> Void)?
    /// Fired on the main queue when an incoming invite arrives; bool = one-way
    /// video share (GUI parity: banner + auto-open).
    var onIncoming: ((_ peerID: String, _ watchOnly: Bool) -> Void)?

    private let stateObservers = NSHashTable<AnyObject>.weakObjects()

    /// Registers a screen to be told when call state changes; held weakly.
    func addStateObserver(_ observer: CallStateObserver) {
        stateObservers.add(observer)
    }

    private let client = DaemonClient()
    private var frameTimer: Timer?
    private var framePath: String?
    private var frameDeadline: Date?
    private var lastFrameSize = -1

    private var peer: String?
    private var callStartedAt: Date?
    private var pendingInvite: (peer: String, ticket: String)?
    private var joinedTicket: String?
    /// media=video invites open a watch-only session (no own publish).
    private var pendingIsWatchOnly = false
    private var watching = false
    /// Latest decoded remote frame (rendered via onFrame; also readable).
    private(set) var lastFrame: NSImage?

    var activePeer: String? { peer }
    var pendingPeer: String? { pendingInvite?.peer }
    /// True when the pending invite is a one-way video share (Watch vs Answer).
    var pendingWatchOnly: Bool { pendingIsWatchOnly }

    func clearError() {
        lastError = nil
        notify()
    }

    // MARK: - Send gating (§3 State 3)

    /// What the session carries: both tracks for a call, none for a watch-only
    /// session (which never publishes).
    private(set) var audioAvailable = false
    private(set) var videoAvailable = false
    /// Whether each stream is currently *sent* (send/no-send gating, never
    /// track attach/detach).
    private(set) var audioEnabled = false
    private(set) var videoEnabled = false
    /// The own-media publish exists (set after `media_live_start` succeeds).
    private var published = false

    func recoverStaleCall() {
        guard let peer = UserDefaults.standard.string(forKey: "idfon.video-call.peer") else { return }
        UserDefaults.standard.removeObject(forKey: "idfon.video-call.peer")
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_video_stop()
            media_live_unsubscribe()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? await self.client.sendText(to: peer, "call_stopped")
        }
    }

    /// Mute/unmute outgoing audio: disabled sends silence, capture stays open.
    func setAudioEnabled(_ enabled: Bool) {
        guard audioAvailable else { return }
        audioEnabled = enabled
        applySendState()
        notify()
    }

    /// Stop/start outgoing video: disabled sends no frames. Enabling also brings
    /// the camera up, since a mic-first call never started capture.
    func setVideoEnabled(_ enabled: Bool) {
        guard videoAvailable else { return }
        if enabled {
            CameraPusher.shared.start()
            NSLog("idfon video: enabling camera capture; published=\(published) video=\(videoEnabled)")
        } else {
            CameraPusher.shared.stop()
            NSLog("idfon video: disabling camera capture; published=\(published)")
        }
        videoEnabled = enabled
        applySendState()
        notify()
    }

    /// Pushes the current send state to the published session (no-op while the
    /// publish is still in flight, or after it stopped).
    private func applySendState() {
        guard published else { return }
        let audio: UInt8 = audioEnabled ? 1 : 0
        let video: UInt8 = videoEnabled ? 1 : 0
        let hasAudio = audioAvailable
        let hasVideo = videoAvailable
        Task.detached(priority: .userInitiated) {
            if hasAudio { _ = media_live_set_audio_enabled(audio) }
            if hasVideo { _ = media_live_set_video_enabled(video) }
        }
    }

    // MARK: - FFI wrappers (blocking C calls must leave the main thread)

    private func ffiString(_ body: @escaping () -> UnsafeMutablePointer<CChar>?) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let ptr = body() else { return "" }
            defer { rust_free_string(ptr) }
            return String(cString: ptr)
        }.value
    }

    // MARK: - Dialer

    /// Starts a video call: session registry entry, own mic+camera publish,
    /// invite to the peer. The peer's answer triggers the return leg in
    /// handleEnvelope.
    func dial(_ peerRef: String, cameraOn: Bool = true) {
        guard state == .idle else { return }
        // Both tracks are published; a mic-first call keeps the camera off until
        // the Bar's toggle calls `setVideoEnabled(true)`.
        audioAvailable = true
        videoAvailable = true
        audioEnabled = true
        videoEnabled = cameraOn
        peer = peerRef
        callStartedAt = Date()
        state = .calling
        notify()
        Task {
            do {
                // Resolve the peer ref (name/alias/id) to the canonical peer
                // id: the daemon's grant check matches grant.subject exactly.
                let id: String
                if let list = try? await client.request(method: "peers"),
                   let peers = list["peers"]?.asArray,
                   let match = peers.first(where: {
                       $0["id"]?.stringValue == peerRef || $0["name"]?.stringValue == peerRef
                           || $0["aliases"]?.asArray?.contains { $0.stringValue == peerRef } == true
                   }),
                   let resolved = match["id"]?.stringValue, !resolved.isEmpty {
                    id = resolved
                } else {
                    id = peerRef
                }
                peer = id
                UserDefaults.standard.set(id, forKey: "idfon.video-call.peer")
                // Registry entry for Idfon's authorization/session lifecycle;
                // native Swift owns capture while the media bridge owns transport.
                let identity = (try? await client.identityId()) ?? "default"
                let peerBytes = Array(id.utf8.map { AnyEncodable(Int($0)) })
                _ = try? await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_video"),
                    "mode": AnyEncodable("record"),
                ])
                // Start capture first so the dylib sees the real camera
                // dimensions when it configures the H.264 encoder. A mic-first
                // call skips this; `setVideoEnabled(true)` starts it later.
                if cameraOn { CameraPusher.shared.start() }
                AudioMeter.shared.pushToEncoder = true
                guard await AudioMeter.shared.startForCall() else {
                    fail("microphone unavailable")
                    return
                }
                let ticket = await ffiString { media_live_start_with_source(1, 1, "push") } // shell-tap audio + camera
                guard !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                applySendState()
                try await client.sendText(to: id, LiveInvite.build(action: "start", ticket: ticket, call: true))
                if case .calling = state { /* still waiting for the return leg */ }
                await waitForReturnInvite(peer: id)
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    /// Answers: watch + hear the caller, publish own camera, send the
    /// return-leg invite (own ticket) that makes the caller join us.
    func answer() {
        guard state == .incoming, let pending = pendingInvite else { return }
        let watchOnly = pendingIsWatchOnly
        pendingInvite = nil
        pendingIsWatchOnly = false
        peer = pending.peer
        state = watchOnly ? .watching : .inCall
        watching = watchOnly
        // A call publishes both tracks but starts mic-only; a watch-only session
        // has no own publish at all, so its toggles stay hidden.
        audioAvailable = !watchOnly
        videoAvailable = !watchOnly
        audioEnabled = !watchOnly
        videoEnabled = false
        notify()
        Task {
            do {
                await join(ticket: pending.ticket)
                if watchOnly {
                    // One-way share: signal receipt so the sender's UI clears.
                    try? await client.sendText(to: pending.peer, "call_started")
                    return
                }
                // Mic-first: capture stays down until `setVideoEnabled(true)`.
                AudioMeter.shared.pushToEncoder = true
                guard await AudioMeter.shared.startForCall() else {
                    fail("microphone unavailable")
                    return
                }
                let own = await ffiString { media_live_start_with_source(1, 1, "push") }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                applySendState()
                try await client.sendText(to: pending.peer, LiveInvite.build(action: "start", ticket: own, call: true))
            } catch {
                fail("Answer failed: \(error.localizedDescription)")
            }
        }
    }

    func decline() {
        guard state == .incoming, let pending = pendingInvite else { return }
        pendingInvite = nil
        pendingIsWatchOnly = false
        state = .idle
        notify()
        // call_stopped mirrors core.ts live_decline so the caller's UI clears.
        Task { try? await client.sendText(to: pending.peer, "call_stopped") }
    }

    func hangUp() {
        terminate(local: true)
    }

    /// Clears a restored/stale call before launch-argument automation starts.
    func resetForAutomation() {
        guard state != .idle else { return }
        terminate(local: false)
    }

    // MARK: - Event routing (called by ChatStore on the main actor)

    /// Handles a call-control message from `peerID`. Invite envelopes and
    /// call control texts are consumed (never shown as chat history).
    func handleEnvelope(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational only
        if text == "call_stopped" {
            if state != .idle && peer == peerID { terminate(local: false) }
            return
        }
        guard let invite = LiveInvite.parse(text) else { return }
        if invite.isStop {
            if state != .idle && peer == peerID { terminate(local: false) }
            return
        }
        guard invite.isStart, !invite.ticket.isEmpty else { return }
        let watchOnly = invite.media == "video" // audio invites route to LiveCall
        guard watchOnly || invite.media == "video-call" else { return }
        if state == .calling || state == .inCall {
            NSLog("idfon video return invite from \(peerID), state=\(state)")
            peer = peerID
            Task { await join(ticket: invite.ticket) }
        } else if state == .incoming {
            // A newer invite from the same peer supersedes the stale pending call.
            guard pendingPeer == peerID else { return }
            pendingInvite = (peerID, invite.ticket)
            pendingIsWatchOnly = watchOnly
            NSLog("idfon video: replaced pending invite from \(peerID)")
            notify()
        } else if state == .idle {
            pendingInvite = (peerID, invite.ticket)
            UserDefaults.standard.set(peerID, forKey: "idfon.video-call.peer")
            pendingIsWatchOnly = watchOnly
            state = watchOnly ? .watching : .incoming
            notify()
            onIncoming?(peerID, watchOnly)
        }
    }

    private func waitForReturnInvite(peer: String) async {
        for attempt in 0..<80 {
            guard state == .calling || state == .inCall else { return }
            do {
                let events = try await client.events(after: nil)
                if let event = events.first(where: {
                    guard let text = $0.messageText, let invite = LiveInvite.parse(text) else { return false }
                    guard let timestamp = Double($0.timestamp), let started = callStartedAt?.timeIntervalSince1970 else { return false }
                    return $0.messagePeerId == peer && invite.isStart && invite.media == "video-call" && timestamp >= started - 2
                }), let text = event.messageText {
                    NSLog("idfon video return invite found attempt=\(attempt) event=\(event.eventId)")
                    handleEnvelope(peer: peer, text)
                    return
                }
                if attempt == 0 || attempt % 10 == 0 { NSLog("idfon video waiting return invite peer=\(peer) events=\(events.count)") }
            } catch { NSLog("idfon video return poll failed: \(error.localizedDescription)") }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Internals

    /// Subscribes audio/video through Idfon's current media bridge; Swift owns
    /// the call UI and lifecycle while the bridge owns MoQ decode resources.
    private func join(ticket: String) async {
        // The return invite arrives through both ChatStore and
        // waitForReturnInvite; the second must not restart the watch.
        guard joinedTicket != ticket else { return }
        joinedTicket = ticket
        let path = await ffiString { media_video_start(ticket) }
        guard !path.isEmpty else {
            let error = await ffiString { media_video_last_error() }
            fail("video watch failed\(error.isEmpty ? "" : ": \(error)")")
            return
        }
        if !watching {
            let subscribeResult = await Task.detached(priority: .userInitiated) { media_live_subscribe(ticket) }.value
            guard subscribeResult == 0 else {
                fail("video audio subscribe failed")
                return
            }
        }
        if state == .idle { return } // hung up while subscribing
        NSLog("idfon video watch started path=\(path)")
        framePath = path
        frameDeadline = Date().addingTimeInterval(10)
        lastFrameSize = -1
        startFramePolling()
        if state == .calling { state = .inCall }
        notify()
    }

    private func terminate(local: Bool) {
        if local, let peerID = peer {
            // Watch-only sessions never signalled an invite of their own.
            Task { try? await client.sendText(to: peerID, watching ? "call_stopped" : LiveInvite.build(action: "stop", ticket: "", call: true)) }
        }
        frameTimer?.invalidate()
        frameTimer = nil
        framePath = nil
        frameDeadline = nil
        joinedTicket = nil
        lastFrameSize = -1
        watching = false
        lastFrame = nil
        published = false
        UserDefaults.standard.removeObject(forKey: "idfon.video-call.peer")
        audioAvailable = false
        videoAvailable = false
        audioEnabled = false
        videoEnabled = false
        AudioMeter.shared.stop()
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_video_stop()
            media_live_unsubscribe()
        }
        CameraPusher.shared.stop()
        state = .idle
        peer = nil
        callStartedAt = nil
        pendingInvite = nil
        notify()
        onFrame?(nil)
    }

    private func fail(_ message: String) {
        NSLog("idfon video call failed: \(message)")
        lastError = message
        // Tell the peer: they were invited (or answered) and would otherwise
        // sit in a one-sided call until they hang up themselves.
        terminate(local: true) // surfaces lastError via state change
    }

    /// Rewrites the remote frame into the UI ~10x/s. The FFI renames a new
    /// The current bridge publishes decoded frames through an atomic native
    /// image artifact; reload only when its size changes.
    private func startFramePolling() {
        frameTimer?.invalidate()
        // Timer fires on the main runloop; hop through the main actor for
        // the MainActor-isolated state.
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let path = self.framePath else { return }
                let size = await Task.detached(priority: .userInitiated) {
                    (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? -1
                }.value
                guard size > 0 else {
                    if let deadline = self.frameDeadline, Date() > deadline {
                        // No picture yet is normal: the peer's camera may be off
                        // (calls start mic-first) and its video track only
                        // exists once it enables it. Only a reported watch
                        // failure ends the call.
                        self.frameDeadline = nil
                        let error = await self.ffiString { media_video_last_error() }
                        if !error.isEmpty {
                            self.fail("video watch failed: \(error)")
                            return
                        }
                        NSLog("idfon video: no remote frame yet (peer camera off?)")
                    }
                    // No frame written yet, or the FFI removed the stale JPEG
                    // (new subscription / peer camera off). Drop any frame
                    // still on screen so a paused stream cannot masquerade as
                    // live video.
                    if self.lastFrame != nil {
                        self.lastFrame = nil
                        self.onFrame?(nil)
                    }
                    self.lastFrameSize = -1
                    return
                }
                guard size != self.lastFrameSize else { return }
                self.lastFrameSize = size
                self.frameDeadline = nil
                // Decode off the main thread: a JPEG decode ~10x/s would
                // otherwise eat main-thread time for the whole call.
                // kCGImageSourceShouldCacheImmediately forces eager decode
                // on the calling thread; NSImage(contentsOfFile:) defers it
                // to first draw (main).
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    let url = URL(fileURLWithPath: path) as CFURL
                    let src = CGImageSourceCreateWithURL(url, nil)
                    let cg = src.flatMap {
                        CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    }
                    let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    await MainActor.run {
                        self.lastFrame = image
                        self.onFrame?(image)
                    }
                }
            }
        }
    }

    private func notify() {
        for case let observer as CallStateObserver in stateObservers.allObjects {
            observer.callStateDidChange()
        }
    }

}
