import AppKit
import Foundation
import CIdfon

/// Latest in-memory video frame from the Rust bridge. The mac shell always
/// registers a renderer; the FFI falls back to video-frame.jpg only when no
/// callback is set (e.g. the Native SDK GUI).
private final class VideoFrameInbox {
    static let shared = VideoFrameInbox()
    private let lock = NSLock()
    private var latest: (data: Data, width: Int, height: Int)?

    func deliver(data: Data, width: Int, height: Int) {
        lock.lock()
        latest = (data, width, height)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    func take() -> (Data, Int, Int)? {
        lock.lock()
        defer { lock.unlock() }
        let value = latest
        latest = nil
        return value
    }
}

/// C callback invoked on a Rust media thread. The inbox is a singleton, so no
/// Swift object lifetime crosses the FFI boundary. The buffer is borrowed;
/// copy before returning. `len == 0` means "clear".
private let videoRenderCallback: @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt8>?, Int, UInt32, UInt32, UInt64) -> Void = { _, data, len, width, height, _ in
    guard let data, len > 0, width > 0, height > 0 else {
        VideoFrameInbox.shared.clear()
        return
    }
    autoreleasepool {
        VideoFrameInbox.shared.deliver(data: Data(bytes: data, count: len), width: Int(width), height: Int(height))
    }
}

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
    /// The peer's answer to our dial (wire: `return=1`; Swift return legs do
    /// not set it, so acceptance never depends on it).
    let isReturn: Bool
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
            isReturn: fields["return"] == "1",
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
        guard case .idle = life.phase else {
            CallFeedback.post("A call is already in progress.")
            return
        }
        let profile = ContactAudioProfiles.profile(for: peerId)
        // Stereo (docs/stereo-calls.md): the panel's audio mode picks the
        // stream layout; pcm24k voice-agent calls stay mono — that plane is
        // 20 ms mono PCM frames into ASR/TTS.
        let channels = profile.sampleRate == 48_000 ? AudioMeter.captureChannelsForCall() : 1
        AudioMeter.shared.configureForCall(sampleRate: profile.sampleRate, channels: channels)
        operation?.cancel()
        audioEnabled = true // this session carries audio from the start
        apply(.dial(peer: peerId))
        CallTonePlayer.shared.start(.ringback)
        let epoch = life.epoch
        operation = Task {
            do {
                // Resolve the ref (name/alias/id) to the canonical id before
                // the invite goes out: the machine correlates the return leg
                // and stops by peer, and envelopes arrive under the sender's
                // id (#51 E2E: dialing "iphone" rejected the answer —
                // "ignored invite … call is with iphone").
                var id = peerId
                if let list = try? await client.request(method: "peers"),
                   let peers = list["peers"]?.asArray,
                   let match = peers.first(where: {
                       $0["id"]?.stringValue == peerId || $0["name"]?.stringValue == peerId
                           || $0["aliases"]?.asArray?.contains { $0.stringValue == peerId } == true
                   }),
                   let resolved = match["id"]?.stringValue, !resolved.isEmpty {
                    id = resolved
                }
                apply(.resolve(peer: id))
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
                guard await AudioMeter.shared.startForCall(sampleRate: profile.sampleRate, channels: channels) else {
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
                // Hung up while the publish was in flight: stop it rather than
                // leaking it and ringing the peer.
                guard case .dialing = life.phase else {
                    Task.detached(priority: .userInitiated) { media_live_stop() }
                    return
                }
                published = true
                apply(.published(ticket: ticket))
                applySendState()
                Automation.mark("live: sending invite peer=\(peerId) ticket_len=\(ticket.count)")
                // Tell the agent which half(s) this device runs (hybrid route);
                // nil when the holder runs both, so no context line is sent.
                let inviteContext = SpeechEngines.clientHalfContext(
                    for: peerId, route: CapabilityTickets.voiceRoute(for: peerId))
                // Reset the model history before the call: the session log is the
                // medium, never the model's context (docs/session-context.md).
                try? await client.sendText(to: peerId, "IDFON-SESSION/1\naction=rotate")
                try await client.sendText(
                    to: peerId,
                    "IDFON-LIVE/1\naction=start\nticket=\(ticket)\naudio_codec=\(profile.codec)\naudio_sample_rate=\(profile.sampleRate)\(ContactVoiceSelection.inviteLines(for: peerId, context: inviteContext))"
                )
                // Wake the peer's devices on a `call_kit` channel (P2): ring
                // via the edge once the invite is queued. The call_uuid is the
                // invite ticket's, so push and envelope share one system call.
                await CallRing.ring(peer: peerId, inviteTicket: ticket, hasVideo: false)
            } catch {
                let ns = error as NSError
                fail("Dial failed: \(error.localizedDescription) [\(ns.domain) code=\(ns.code)]")
            }
        }
    }

    // MARK: - Callee

    func answer() {
        guard case .incoming(let pending) = life.phase else { return }
        let profile = ContactAudioProfiles.profile(for: pending.peer)
        // Stereo as on the caller leg (see `dial`).
        let channels = profile.sampleRate == 48_000 ? AudioMeter.captureChannelsForCall() : 1
        AudioMeter.shared.configureForCall(sampleRate: profile.sampleRate, channels: channels)
        audioEnabled = true
        operation?.cancel()
        apply(.answer)
        let epoch = life.epoch
        CallTonePlayer.shared.stop()
        operation = Task {
            do {
                await join(ticket: pending.ticket)
                guard life.epoch == epoch, !Task.isCancelled else { return }
                // Torn down while subscribing (`fail` already ended the call):
                // never publish into a dead session.
                guard case .connected = life.phase else { return }
                // Publish our own mic so audio is two-way, then send the
                // return-leg invite (own ticket) that makes the caller join us.
                AudioMeter.shared.pushToEncoder = true
                guard await AudioMeter.shared.startForCall(sampleRate: profile.sampleRate, channels: channels) else {
                    fail("microphone unavailable")
                    return
                }
                let own = await ffiString {
                    media_live_start_with_profile(1, 0, "push", profile.codec, UInt32(profile.sampleRate), UInt32(channels))
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
        guard case .incoming = life.phase else { return }
        CallTonePlayer.shared.stop()
        apply(.hangUp)
    }

    func hangUp() {
        joinedTicket = nil
        apply(.hangUp)
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
        guard let invite = LiveInvite.parse(text) else { return }
        if invite.isStop {
            apply(.remoteStop(peer: peerID, ticket: invite.ticket.isEmpty ? nil : invite.ticket))
            return
        }
        guard invite.isStart, invite.media == nil else {
            idfonLog("idfon live call: ignored non-audio envelope from \(peerID)")
            return
        }
        // A leg on our call (return leg / re-publish) comes back as a `.join`
        // effect; a fresh invite rings and supersedes via the machine.
        apply(.invite(CallLifecycle.Invite(
            peer: peerID, ticket: invite.ticket, isReturn: invite.isReturn, watchOnly: false)))
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

    /// The panel picked an audio route (docs/stereo-calls.md): unmute, and when
    /// the route changes the stream layout (stereo ↔ mono) re-publish the mic
    /// leg and re-send the invite — the peer's handler re-joins on a fresh
    /// invite.
    func setAudioMode(_ mode: CallAudioMode) {
        setAudioEnabled(true)
        guard published, let peer = activePeer else { return }
        let want = ContactAudioProfiles.profile(for: peer) == .pcm24k
            ? 1
            : AudioMeter.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republishAudio(channels: want, peer: peer) }
    }

    /// The panel's Stereo toggle: re-publish the mic leg when it changes the
    /// stream layout (silence at the new layout keeps a muted leg simple).
    func setStereo(_ on: Bool) {
        guard published, let peer = activePeer else { return }
        let want = ContactAudioProfiles.profile(for: peer) == .pcm24k
            ? 1
            : AudioMeter.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republishAudio(channels: want, peer: peer) }
    }

    /// Re-publish the mic leg at a new channel count and re-invite the peer.
    private func republishAudio(channels: Int, peer: String) async {
        let profile = ContactAudioProfiles.profile(for: peer)
        AudioMeter.shared.retarget(channels: channels)
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
            if let ticket {
                Task { try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: false)) }
            } else {
                // The call never got a generation (ended before its publish
                // landed): legacy bare stop.
                Task { try? await self.client.sendText(to: peer, "call_stopped") }
            }
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
            AudioMeter.shared.stop()
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
            CallTonePlayer.shared.start(.ringtone)
            onIncoming?(peer)
        case .changed:
            notify()
        case .remoteEnded:
            break
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
    /// The call generation's identity (the dialer's publish ticket), nil when
    /// no call exists.
    var callGeneration: String? { life.generation }

    func clearError() {
        lastError = nil
        notify()
    }

    /// A process crash cannot send the normal stop envelope. On the next
    /// launch, close the persisted session at the peer before accepting calls.
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

    /// Subscribes to a peer ticket without tearing the call down on failure.
    /// The far end's ticket, for the connection health check (§B2.2).
    private(set) var joinedTicket: String?

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
        joinedTicket = ticket
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
        // Wake-channel bookkeeping (P2): a rang call that goes idle without
        // connecting is cancelled; a connection clears the pending ring.
        switch state {
        case .inCall: CallRing.callConnected()
        case .idle: CallRing.cancelRing()
        default: break
        }
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

    /// The call lifecycle (phase, peer, generation, epoch): the single source
    /// of truth — `state` and the rest are views over it (CallLifecycle.swift;
    /// every transition's effects run in `run`).
    private var life = CallLifecycle()
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

    private var callStartedAt: Date?
    private(set) var joinedTicket: String?
    /// Latest decoded remote frame (rendered via onFrame; also readable).
    private(set) var lastFrame: NSImage?

    /// The call's peer in every non-idle phase (a ring names its caller).
    var activePeer: String? { life.peer }
    var pendingPeer: String? {
        if case .incoming(let invite) = life.phase { return invite.peer }
        return nil
    }
    /// True when the pending invite is a one-way video share (Watch vs Answer).
    var pendingWatchOnly: Bool {
        if case .incoming(let invite) = life.phase { return invite.watchOnly }
        return false
    }

    var state: State {
        switch life.phase {
        case .idle: return .idle
        case .incoming: return .incoming
        case .dialing: return .calling
        case .watching: return .watching
        case .connected: return .inCall
        }
    }

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
    /// The channel count the audio leg publishes (1 mono, 2 = the 2D mode).
    private var publishedChannels = 1

    func recoverStaleCall() {
        guard let peer = UserDefaults.standard.string(forKey: "idfon.video-call.peer") else { return }
        // The crash left the call generation behind; name it so a live call
        // that took its place is not ended by this recovery stop (#60).
        let ticket = UserDefaults.standard.string(forKey: "idfon.video-call.ticket") ?? ""
        UserDefaults.standard.removeObject(forKey: "idfon.video-call.peer")
        UserDefaults.standard.removeObject(forKey: "idfon.video-call.ticket")
        Task.detached(priority: .userInitiated) {
            media_live_stop()
            media_video_stop()
            media_live_unsubscribe()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: true))
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
            idfonLog("idfon video: enabling camera capture; published=\(published) video=\(videoEnabled)")
        } else {
            CameraPusher.shared.stop()
            idfonLog("idfon video: disabling camera capture; published=\(published)")
        }
        videoEnabled = enabled
        applySendState()
        notify()
    }

    /// The panel picked an audio route (docs/stereo-calls.md): unmute, and when
    /// the route changes the stream layout (stereo ↔ mono) re-publish and
    /// re-invite — the peer's handler re-joins on a fresh invite.
    func setAudioMode(_ mode: CallAudioMode) {
        setAudioEnabled(true)
        guard published, let peer = activePeer, !peer.isEmpty else { return }
        let want = AudioMeter.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republish(channels: want, peer: peer) }
    }

    /// The panel's Stereo toggle: re-publish when it changes the stream layout
    /// (silence at the new layout keeps a muted leg simple).
    func setStereo(_ on: Bool) {
        guard published, let peer = activePeer, !peer.isEmpty else { return }
        let want = AudioMeter.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republish(channels: want, peer: peer) }
    }

    /// Re-publish both tracks at a new audio channel count and re-invite.
    private func republish(channels: Int, peer: String) async {
        AudioMeter.shared.retarget(channels: channels)
        await Task.detached(priority: .userInitiated) { media_live_stop() }.value
        let ticket = await ffiString {
            media_live_start_with_profile(1, 1, "push", "opus", 48_000, UInt32(channels))
        }
        guard !ticket.isEmpty else {
            idfonError("idfon video: re-publish failed for \(channels)ch")
            return
        }
        publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
        // No generation change here on purpose: stops must keep naming the
        // call's original ticket (CallLifecycle.generation).
        applySendState()
        do {
            try await client.sendText(to: peer, LiveInvite.build(action: "start", ticket: ticket, call: true))
            idfonLog("idfon video: re-published tracks channels=\(channels)")
        } catch {
            idfonError("idfon video: re-publish invite failed: \(error)")
        }
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
        guard case .idle = life.phase else {
            CallFeedback.post("A call is already in progress.")
            return
        }
        // Both tracks are published; a mic-first call keeps the camera off until
        // the Bar's toggle calls `setVideoEnabled(true)`.
        audioAvailable = true
        videoAvailable = true
        audioEnabled = true
        videoEnabled = cameraOn
        callStartedAt = Date()
        apply(.dial(peer: peerRef))
        CallTonePlayer.shared.start(.ringback)
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
                apply(.resolve(peer: id))
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
                let ticket = await ffiString {
                    media_live_start_with_profile(1, 1, "push", "opus", 48_000, UInt32(AudioMeter.captureChannelsForCall()))
                } // shell-tap audio + camera
                guard !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                publishedChannels = AudioMeter.captureChannelsForCall()
                apply(.published(ticket: ticket))
                applySendState()
                try await client.sendText(to: id, LiveInvite.build(action: "start", ticket: ticket, call: true))
                // Wake the peer's devices on a `call_kit` channel (P2): ring
                // via the edge once the invite is queued (call_uuid = the
                // invite ticket's, so push and envelope share one call).
                await CallRing.ring(peer: id, inviteTicket: ticket, hasVideo: true)
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
        guard case .incoming(let pending) = life.phase else { return }
        let watchOnly = pending.watchOnly
        // A call publishes both tracks but starts mic-only; a watch-only session
        // has no own publish at all, so its toggles stay hidden.
        audioAvailable = !watchOnly
        videoAvailable = !watchOnly
        audioEnabled = !watchOnly
        videoEnabled = false
        apply(.answer)
        CallTonePlayer.shared.stop()
        Task {
            do {
                await join(ticket: pending.ticket, answered: false)
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
                let own = await ffiString {
                    media_live_start_with_profile(1, 1, "push", "opus", 48_000, UInt32(AudioMeter.captureChannelsForCall()))
                }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                publishedChannels = AudioMeter.captureChannelsForCall()
                applySendState()
                try await client.sendText(to: pending.peer, LiveInvite.build(action: "start", ticket: own, call: true))
            } catch {
                fail("Answer failed: \(error.localizedDescription)")
            }
        }
    }

    func decline() {
        guard case .incoming = life.phase else { return }
        CallTonePlayer.shared.stop()
        apply(.hangUp)
    }

    func hangUp() {
        apply(.hangUp)
    }

    /// Clears a restored/stale call before launch-argument automation starts.
    func resetForAutomation() {
        apply(.abandon)
    }

    // MARK: - Event routing (called by ChatStore on the main actor)

    /// Handles a call-control message from `peerID`. Invite envelopes and
    /// call control texts are consumed (never shown as chat history).
    func handleEnvelope(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational only
        if text == "call_stopped" {
            apply(.remoteStop(peer: peerID, ticket: nil))
            return
        }
        guard let invite = LiveInvite.parse(text) else { return }
        if invite.isStop {
            apply(.remoteStop(peer: peerID, ticket: invite.ticket.isEmpty ? nil : invite.ticket))
            return
        }
        guard invite.isStart else { return }
        let watchOnly = invite.media == "video" // audio invites route to LiveCall
        guard watchOnly || invite.media == "video-call" else { return }
        // A leg on our call (return leg / re-publish) comes back as a `.join`
        // effect; a fresh invite rings (or supersedes) via the machine.
        apply(.invite(CallLifecycle.Invite(
            peer: peerID, ticket: invite.ticket, isReturn: invite.isReturn, watchOnly: watchOnly)))
    }

    private func waitForReturnInvite(peer: String) async {
        for attempt in 0..<80 {
            switch life.phase {
            case .dialing, .connected: break
            default: return
            }
            do {
                let events = try await client.events(after: nil)
                if let event = events.first(where: {
                    guard let text = $0.messageText, let invite = LiveInvite.parse(text) else { return false }
                    guard let timestamp = Double($0.timestamp), let started = callStartedAt?.timeIntervalSince1970 else { return false }
                    return $0.messagePeerId == peer && invite.isStart && invite.media == "video-call" && timestamp >= started - 2
                }), let text = event.messageText {
                    idfonLog("idfon video return invite found attempt=\(attempt) event=\(event.eventId)")
                    handleEnvelope(peer: peer, text)
                    return
                }
                if attempt == 0 || attempt % 10 == 0 { idfonLog("idfon video waiting return invite peer=\(peer) events=\(events.count)") }
            } catch { idfonError("idfon video return poll failed: \(error.localizedDescription)") }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Internals

    /// Subscribes audio/video through Idfon's current media bridge; Swift owns
    /// the call UI and lifecycle while the bridge owns MoQ decode resources.
    private func join(ticket: String, answered: Bool) async {
        // The return invite arrives through both ChatStore and
        // waitForReturnInvite; the second must not restart the watch.
        guard joinedTicket != ticket else { return }
        joinedTicket = ticket
        if answered {
            CallTonePlayer.shared.start(.answered) // caller: answer cue
        } else {
            CallTonePlayer.shared.stop() // callee: stop the incoming ringtone
        }
        VideoFrameInbox.shared.clear()
        _ = media_video_set_render_cb(nil, videoRenderCallback)
        let path = await ffiString { media_video_start(ticket) }
        guard !path.isEmpty else {
            let error = await ffiString { media_video_last_error() }
            fail("video watch failed\(error.isEmpty ? "" : ": \(error)")")
            return
        }
        if case .watching = life.phase {} else {
            let subscribeResult = await Task.detached(priority: .userInitiated) { media_live_subscribe(ticket) }.value
            guard subscribeResult == 0 else {
                fail("video audio subscribe failed")
                return
            }
        }
        if case .idle = life.phase { return } // hung up while subscribing
        idfonLog("idfon video watch started path=\(path)")
        startFramePolling()
        notify()
    }

    private func fail(_ message: String) {
        idfonError("idfon video call failed: \(message)")
        lastError = message
        CallFeedback.post("No live call available: \(message)")
        // The machine's `.fail` end tells the peer too: they were invited (or
        // answered) and would otherwise sit in a one-sided call.
        apply(.fail(message))
    }

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
            if let ticket {
                Task { try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: true)) }
            } else {
                // The call never got a generation (ended before its publish
                // landed): legacy bare stop.
                Task { try? await self.client.sendText(to: peer, "call_stopped") }
            }
        case .join(let ticket, let answersDial):
            Task { await self.join(ticket: ticket, answered: answersDial) }
        case .stopMedia:
            frameTimer?.invalidate()
            frameTimer = nil
            media_video_clear_render_cb()
            VideoFrameInbox.shared.clear()
            joinedTicket = nil
            callStartedAt = nil
            lastFrame = nil
            published = false
            audioAvailable = false
            videoAvailable = false
            audioEnabled = false
            videoEnabled = false
            AudioMeter.shared.stop()
            CameraPusher.shared.stop()
            Task.detached(priority: .userInitiated) {
                media_live_stop()
                Diag.logCallRecord() // the record folds inside the stop: ship once, here
                media_video_stop()
                media_live_unsubscribe()
            }
            onFrame?(nil)
        case .endCue:
            CallTonePlayer.shared.start(.ended)
        case .quiet:
            CallTonePlayer.shared.stop()
        case .ring(let peer):
            if !pendingWatchOnly { CallTonePlayer.shared.start(.ringtone) }
            onIncoming?(peer, pendingWatchOnly)
        case .changed:
            notify()
        case .remoteEnded:
            break
        case .log(let message):
            idfonLog("idfon video call: \(message)")
        }
    }

    /// Crash recovery reads these; keeping them in step with the machine here
    /// replaces the per-callsite writes that flows used to skip.
    private func persist() {
        let defaults = UserDefaults.standard
        if let peer = life.peer {
            defaults.set(peer, forKey: "idfon.video-call.peer")
        } else {
            defaults.removeObject(forKey: "idfon.video-call.peer")
        }
        if let generation = life.generation {
            defaults.set(generation, forKey: "idfon.video-call.ticket")
        } else {
            defaults.removeObject(forKey: "idfon.video-call.ticket")
        }
    }

    /// Rewrites the remote frame into the UI ~10x/s. The FFI renames a new
    /// Pulls the latest in-memory frame from the Rust bridge ~10x/s.
    private func startFramePolling() {
        frameTimer?.invalidate()
        // Timer fires on the main runloop; hop through the main actor for
        // the MainActor-isolated state.
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollInMemoryFrame()
            }
        }
    }

    private func pollInMemoryFrame() {
        guard let (data, width, height) = VideoFrameInbox.shared.take() else {
            if lastFrame != nil {
                lastFrame = nil
                onFrame?(nil)
            }
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let provider = CGDataProvider(data: data as CFData)
            let cg = provider.flatMap {
                CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            }
            let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            guard let self else { return }
            await MainActor.run {
                self.lastFrame = image
                self.onFrame?(image)
            }
        }
    }

    private func notify() {
        // Wake-channel bookkeeping (P2): a rang call that goes idle without
        // connecting is cancelled; a connection clears the pending ring.
        switch state {
        case .inCall: CallRing.callConnected()
        case .idle: CallRing.cancelRing()
        default: break
        }
        for case let observer as CallStateObserver in stateObservers.allObjects {
            observer.callStateDidChange()
        }
    }

}

/// Hybrid server-cascade call (macOS mirror of the iOS controller): the holder
/// runs the live session; the caller supplies one half on-device.
@MainActor
final class HybridVoice {
    static let shared = HybridVoice()

    private let client = DaemonClient()
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
        guard !isActive, route.isHybrid else { return }
        isActive = true
        peerId = peerRef
        speakLocal = route.ttsSide == .client
        // Per-contact on-device engine, else the app default.
        if speakLocal {
            tts = SpeechEngines.makeTts(
                ContactOnDeviceEngines.tts(for: peerRef).flatMap(TtsBackend.init(rawValue:)) ?? SpeechEngines.ttsBackend)
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
