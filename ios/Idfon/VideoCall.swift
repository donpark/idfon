import Foundation
import UIKit
import AVFAudio

/// Latest in-memory video frame from the Rust bridge. The iOS shell always
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

/// Parsed IDFON-LIVE/1 invite envelope (native/src/core.ts parseLiveInvite).
/// Shape: "IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=<ticket>"
struct LiveInvite {
    let isStart: Bool
    let isStop: Bool
    /// media line value: nil = audio, "video" = one-way file share,
    /// "video-call" = live camera call.
    let media: String?
    let isCall: Bool // media=video-call (live camera call)
    let isReturn: Bool // holder response to an outgoing call
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
                // ticket values never contain newlines, but be tolerant
                fields[key]? += "\n" + line
            }
        }
        guard let action = fields["action"] else { return nil }
        let media = fields["media"]
        return LiveInvite(
            isStart: action == "start",
            isStop: action == "stop",
            media: media,
            isCall: media == "video-call",
            isReturn: fields["return"] == "1",
            ticket: fields["ticket"] ?? ""
        )
    }

    static func build(action: String, ticket: String, call: Bool) -> String {
        let media = call ? "video-call" : "video"
        return "IDFON-LIVE/1\naction=\(action)\nmedia=\(media)\nticket=\(ticket)"
    }
}

/// 1:1 video-call state machine, mirroring the tested flow in
/// native/src/core.ts (video_call_start / live_answer video-call branch /
/// return-leg branch). The dialer publishes mic+camera and sends an invite
/// carrying its ticket; the callee answers by watching + hearing the caller
/// while publishing its own broadcast and sending its own invite back; the
/// caller receives that return leg and joins it.
///
/// Swift owns camera/audio capture and call UI lifecycle; the Idfon media
/// bridge publishes/subscribes current MoQ tracks and supplies decoded frames.
/// Signaling stays on the daemon socket.
///
/// @MainActor: the frame-polling Timer.scheduledTimer attaches to the
/// current run loop — join()/answer() hop into Tasks that would otherwise
/// land on the cooperative pool (no run loop), where the timer never fires
/// and the remote video pane stays black while the FFI decodes fine
/// (mac's Calls.swift carries the same annotation for the same reason).
@MainActor
final class VideoCall: NSObject {
    static let shared = VideoCall()

    enum State: Equatable { case idle, calling, incoming, inCall }

    /// The call lifecycle (phase, peer, generation, epoch): the single source
    /// of truth — `state` and the rest are views over it (CallLifecycle.swift;
    /// every transition's effects run in `run`).
    private var life = CallLifecycle()
    private(set) var joinedTicket: String?

    var state: State {
        switch life.phase {
        case .idle: return .idle
        case .incoming: return .incoming
        case .dialing: return .calling
        case .connected, .watching: return .inCall
        }
    }

    /// The peer of the call in flight, including an unanswered incoming call —
    /// the machine's incoming state carries its caller, so "ringing but no
    /// invite" cannot exist (the #51 wedge that made Decline a no-op).
    var activePeer: String? { life.peer }

    /// The current call's generation ticket (the dialer's publish ticket),
    /// nil when no call exists — lets a ring push recognize a call the
    /// machines already own (the envelope is queued before the push is sent,
    /// so on a live app it arrives first and the Bar owns the ring, #7).
    var callGeneration: String? { life.generation }
    private(set) var lastError: String?

    // MARK: - Outgoing stream set (docs/ui-design-notes.md §3 State 3)

    /// What the session was published with — set by `dial(audio:video:)` or by
    /// `answer()` (which always publishes both), immutable for the call's life.
    /// A call can only toggle the tracks it was started with.
    private(set) var audioAvailable = false
    private(set) var videoAvailable = false
    /// Whether each stream is currently being *sent* (mute/unmute, camera
    /// on/off); never track attach/detach. Reset when the call ends.
    private(set) var audioEnabled = false
    private(set) var videoEnabled = false
    /// The own-media publish exists (set after `media_live_start` succeeds).
    private var published = false
    /// The channel count the audio leg publishes (1 mono, 2 = the 2D mode).
    private var publishedChannels = 1

    /// Enable/disable outgoing audio. Disabling sends silence (capture stays
    /// open); enabling brings capture up on demand when the call started
    /// video-only and the mic was never started.
    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        // Capture comes up on demand: a video-only dial never started the mic.
        if enabled && !AudioPusher.shared.running {
            Task { [weak self] in
                guard await AudioPusher.shared.startForCall() else { return }
                self?.applySendState()
            }
        }
        applySendState()
        CallKitController.shared.mutedChanged(!enabled)
        notify()
    }

    /// Stop/start outgoing video: disabled sends no frames.
    func setVideoEnabled(_ enabled: Bool) {
        guard videoAvailable else { return }
        // Camera comes up on demand: a mic-first call publishes the video track
        // but doesn't start capture until the toggle is switched on.
        videoEnabled = enabled
        applySendState()
        if enabled {
            CameraPusher.shared.start()
            idfonLog("idfon video: enabling camera capture; published=\(published) video=\(videoEnabled)")
        } else {
            CameraPusher.shared.stop()
            idfonLog("idfon video: disabling camera capture; published=\(published)")
        }
        notify()
    }

    /// The panel picked an audio route (docs/stereo-calls.md): unmute, and when
    /// the route changes the stream layout (stereo ↔ mono) re-publish and
    /// re-invite — the peer's handler re-joins on a fresh invite.
    func setAudioMode(_ mode: CallAudioMode) {
        setAudioEnabled(true)
        guard published, let peer = activePeer, !peer.isEmpty else { return }
        let want = AudioIO.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republish(channels: want, peer: peer) }
    }

    /// The panel's Stereo toggle: re-publish when it changes the stream layout
    /// (silence at the new layout keeps a muted leg simple).
    func setStereo(_ on: Bool) {
        guard published, let peer = activePeer, !peer.isEmpty else { return }
        let want = AudioIO.captureChannelsForCall()
        guard want != publishedChannels else { return }
        Task { [weak self] in await self?.republish(channels: want, peer: peer) }
    }

    /// Re-publish both tracks at a new audio channel count and re-invite.
    private func republish(channels: Int, peer: String) async {
        AudioPusher.shared.retarget(channels: channels)
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
    /// publish is still in flight or already stopped).
    private func applySendState() {
        guard published else { return }
        let audio: UInt8 = audioEnabled ? 1 : 0
        let video: UInt8 = videoEnabled ? 1 : 0
        let hasAudio = audioAvailable
        let hasVideo = videoAvailable
        Task.detached(priority: .userInitiated) {
            if hasAudio { _ = media_live_set_audio_enabled(audio) }
            if hasVideo {
                _ = media_live_set_video_enabled(video)
                idfonLog("idfon video: native gate=\(video)")
            }
        }
    }

    /// Observed on the main queue: state (or error text) changed.
    var onState: (() -> Void)?
    /// Decoded peer frames (~10fps), main queue.
    var onFrame: ((UIImage?) -> Void)?

    private let client = IdfonClient()
    private var frameTimer: Timer?
    /// True while a decoded peer frame is on screen (for clearing it).
    private var peerFrameVisible = false

    // MARK: - FFI wrappers (blocking C calls must leave the main thread)

    private func ffiString(_ body: @escaping () -> UnsafeMutablePointer<CChar>?) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let ptr = body() else { return "" }
            defer { rust_free_string(ptr) }
            return String(cString: ptr)
        }.value
    }

    private func activateAudioSession() {
        LiveCallHarness.activateAudioSession()
    }

    // MARK: - Dialer

    /// Starts a call: session registry entry, own publish, invite to the
    /// peer. Both tracks are always published; `audio`/`video` pick the
    /// initially enabled streams and each can be toggled on or off in-call
    /// (toggles bring capture up on demand). Both false is rejected.
    ///
    /// `cameraOn: false` publishes the video track but sends no frames until
    /// the Bar's camera toggle is switched on — the default for calls started
    /// from the nav bar (mic first).
    func dial(_ peerRef: String, audio: Bool = true, video: Bool = true, cameraOn: Bool = true) {
        Automation.mark("video: dial ref=\(peerRef) audio=\(audio) video=\(video)")
        guard case .idle = life.phase, audio || video else {
            CallFeedback.post("A call is already in progress.")
            return
        }
        // `call_kit` channels dial through the system call UI — CallKit owns
        // the whole call lifecycle, both directions (docs/callkit-integration.md).
        if IncomingCallRouter.shared.ownsPresentation(for: peerRef) {
            CallKitController.shared.startOutgoing(peerId: peerRef, video: true) { [weak self] in
                self?.dialNow(peerRef, audio: audio, video: video, cameraOn: cameraOn)
            }
        } else {
            dialNow(peerRef, audio: audio, video: video, cameraOn: cameraOn)
        }
    }

    private func dialNow(_ peerRef: String, audio: Bool, video: Bool, cameraOn: Bool) {
        audioAvailable = true
        videoAvailable = true
        audioEnabled = audio
        videoEnabled = video && cameraOn
        apply(.dial(peer: peerRef))
        // The cue rides the shared playback bus (AudioIO): start the session
        // first or the tone is dropped before the call arms it.
        activateAudioSession()
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
                // Swift owns capture while the media bridge owns transport.
                let identity = (try? await client.status())?.1 ?? "default"
                let peerBytes = Array(id.utf8.map { AnyEncodable(Int($0)) })
                _ = try await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_video"),
                    "mode": AnyEncodable("record"),
                ])
                activateAudioSession()
                if audio {
                    guard await AudioPusher.shared.startForCall() else {
                        fail("microphone unavailable")
                        return
                    }
                }
                if video && cameraOn { CameraPusher.shared.start() }
                // Publish both tracks regardless of the staged stream set so
                // either stream can be toggled on later in the call. The
                // panel's audio mode picks the audio layout (docs/stereo-calls.md).
                let channels = AudioIO.captureChannelsForCall()
                let ticket = await ffiString {
                    media_live_start_with_profile(1, 1, "push", "opus", 48_000, UInt32(channels))
                }
                guard !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
                apply(.published(ticket: ticket))
                applySendState() // a toggle during `.calling` may predate the publish
                try await client.sendText(to: id, LiveInvite.build(action: "start", ticket: ticket, call: true))
                // Wake the peer's devices on a `call_kit` channel (P2): ring
                // via the edge once the invite is queued (call_uuid = the
                // invite ticket's, so push and envelope share one call).
                if IncomingCallRouter.shared.ownsPresentation(for: id) {
                    PushWake.shared.ring(
                        peer: id, callUUID: CallUUID.from(ticket: ticket).uuidString,
                        hasVideo: true)
                }
            } catch {
                fail("Dial failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Callee

    /// Answers: watch + hear the caller, publish own camera, send the
    /// return-leg invite (own ticket) that makes the caller join us.
    func answer(cameraOn: Bool = true) {
        idfonLog("idfon video: answer state=\(state)")
        guard case .incoming(let pending) = life.phase else {
            idfonLog("idfon video: answer ignored — not incoming")
            return
        }
        // The callee always publishes both tracks, but starts mic-only — the
        // Bar turns the camera on.
        audioAvailable = true
        videoAvailable = true
        audioEnabled = true
        videoEnabled = cameraOn
        apply(.answer)
        Task {
            do {
                activateAudioSession()
                var micReady = await AudioPusher.shared.startForCall()
                if !micReady {
                    // The CallKit session may still be activating (the
                    // didActivate handoff): the engine start then fails with
                    // avfaudio 561017449 and the call must not die on it (#51).
                    idfonLog("idfon video: mic start failed; retrying after the session settles")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    micReady = await AudioPusher.shared.startForCall()
                }
                guard micReady else {
                    fail("microphone unavailable")
                    return
                }
                if cameraOn { CameraPusher.shared.start() }
                await join(ticket: pending.ticket, answered: false)
                let channels = AudioIO.captureChannelsForCall()
                let own = await ffiString {
                    media_live_start_with_profile(1, 1, "push", "opus", 48_000, UInt32(channels))
                }
                guard !own.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                publishedChannels = channels
        // The stereo step's complement (docs/media-adaptation.md §B2.4):
        // mono payload is resilience mode, so FEC follows the layout.
        Task.detached(priority: .userInitiated) { _ = media_audio_set_fec(channels == 1 ? 1 : 0) }
                applySendState()
                idfonLog("idfon video answer media started audio=1 video=\(cameraOn ? 1 : 0)")
                try await client.sendText(to: pending.peer, LiveInvite.build(action: "start", ticket: own, call: true))
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
            _ = try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket, call: true))
        }
    }

    // MARK: - Event routing (called by ChatStore via the main queue)

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
        guard invite.isStart, invite.isCall else { return } // file-share/audio invites: unsupported here
        // A leg on our call (return leg / re-publish) comes back as a `.join`
        // effect; a fresh invite rings (or supersedes) via the machine.
        apply(.invite(CallLifecycle.Invite(
            peer: peerID, ticket: invite.ticket, isReturn: invite.isReturn, watchOnly: false)))
    }

    // MARK: - Internals

    /// Subscribes audio/video through Idfon's current media bridge; Swift owns
    /// the call UI and lifecycle while the bridge owns MoQ decode resources.
    private func join(ticket: String, answered: Bool) async {
        // A return invite can reach us twice (event replay / duplicate
        // delivery); restarting the watch would drop the live frame artifact.
        guard joinedTicket != ticket else { return }
        joinedTicket = ticket
        Automation.mark("video: join")
        if answered {
            CallTonePlayer.shared.start(.answered) // caller: answer cue
        } else {
            CallTonePlayer.shared.stop() // callee: stop the incoming ringtone
        }
        activateAudioSession()
        VideoFrameInbox.shared.clear()
        _ = media_video_set_render_cb(nil, videoRenderCallback)
        let path = await ffiString { media_video_start(ticket) }
        guard !path.isEmpty else {
            let error = await ffiString { media_video_last_error() }
            fail("video watch failed\(error.isEmpty ? "" : ": \(error)")")
            return
        }
        let subscribeResult = await Task.detached(priority: .userInitiated) { media_live_subscribe(ticket) }.value
        guard subscribeResult == 0 else {
            fail("video audio subscribe failed")
            return
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
            // Empty ticket = the call never got a generation (ended before its
            // publish landed); an unticketed stop keeps the legacy behavior.
            Task { try? await self.client.sendText(to: peer, LiveInvite.build(action: "stop", ticket: ticket ?? "", call: true)) }
        case .join(let ticket, let answersDial):
            Task { await self.join(ticket: ticket, answered: answersDial) }
        case .stopMedia:
            frameTimer?.invalidate()
            frameTimer = nil
            media_video_clear_render_cb()
            VideoFrameInbox.shared.clear()
            joinedTicket = nil
            // AudioPusher tear-down must stay on the main queue (engine state is
            // main-serialized); only the blocking FFI calls go to the background.
            AudioPusher.shared.stop()
            Task.detached(priority: .userInitiated) {
                CameraPusher.shared.stop()
                media_live_stop()
                Diag.logCallRecord() // the record folds inside the stop: ship once, here
                media_video_stop()
                media_live_unsubscribe()
            }
            published = false
            audioAvailable = false
            videoAvailable = false
            audioEnabled = false
            videoEnabled = false
            peerFrameVisible = false
            onFrame?(nil)
        case .endCue:
            CallTonePlayer.shared.start(.ended)
        case .quiet:
            CallTonePlayer.shared.stop()
        case .ring(let peer):
            // Answering publishes both tracks but starts mic-only (camera off
            // until the Bar's toggle), so there is nothing to pre-stage.
            audioAvailable = true
            videoAvailable = true
            // The system already rings (a push-first wake): no Bar ringtone
            // and no app-owned audio session alongside it.
            if !CallKitController.shared.isRinging(peer) {
                activateAudioSession()
                CallTonePlayer.shared.start(.ringtone)
            }
        case .changed:
            notify()
        case .remoteEnded(let peer, let ticket):
            // A push-first wake can outlive the machine: the transport truth
            // must end a ringing system call too (#45).
            CallKitController.shared.remoteEnded(peerId: peer, owner: .video, ticket: ticket ?? "")
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
    /// The current bridge supplies decoded frames through a native image
    /// artifact; reload only when its size changes.
    /// Pulls the latest in-memory frame from the Rust bridge ~10x/s.
    private func startFramePolling() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollInMemoryFrame() }
        }
    }

    private func pollInMemoryFrame() {
        guard let (data, width, height) = VideoFrameInbox.shared.take() else {
            if peerFrameVisible {
                peerFrameVisible = false
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
            let image = cg.map { UIImage(cgImage: $0) }
            guard let self else { return }
            await MainActor.run {
                self.peerFrameVisible = image != nil
                self.onFrame?(image)
            }
        }
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
        CallKitController.shared.mirror(owner: .video, phase: phase)
        DispatchQueue.main.async { [self] in
            onState?()
            NotificationCenter.default.post(name: .idfonVideoChanged, object: self)
        }
    }
}

extension Notification.Name {
    static let idfonVideoChanged = Notification.Name("idfon.video.changed")
    static let idfonVideoFrame = Notification.Name("idfon.video.frame")
}
