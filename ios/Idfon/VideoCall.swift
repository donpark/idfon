import Foundation
import UIKit
import AVFAudio

/// Parsed IDFON-LIVE/1 invite envelope (native/src/core.ts parseLiveInvite).
/// Shape: "IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=<ticket>"
struct LiveInvite {
    let isStart: Bool
    let isStop: Bool
    /// media line value: nil = audio, "video" = one-way file share,
    /// "video-call" = live camera call.
    let media: String?
    let isCall: Bool // media=video-call (live camera call)
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
/// Media runs through the vendored c-ffi FFI (camera, H.264 publish, peer
/// video decoded to video-frame.jpg ~15fps); signaling goes over the daemon
/// socket (message.send) like every other chat message.
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

    private(set) var state: State = .idle
    private(set) var peer: String?
    /// The peer of the call in flight, including an unanswered incoming call —
    /// where only `pendingInvite` knows the caller. UI and message routing must
    /// read this, not `peer`: during `.incoming`, `peer` is still nil.
    var activePeer: String? { peer ?? pendingInvite?.peer }
    private(set) var lastError: String?
    private var pendingInvite: (peer: String, ticket: String)?

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

    /// Mute/unmute outgoing audio: disabled sends silence, capture stays open.
    /// A toggle that lands while the publish is still in flight is recorded and
    /// pushed once the session exists.
    func setAudioEnabled(_ enabled: Bool) {
        guard audioAvailable else { return }
        audioEnabled = enabled
        applySendState()
        notify()
    }

    /// Stop/start outgoing video: disabled sends no frames.
    func setVideoEnabled(_ enabled: Bool) {
        guard videoAvailable else { return }
        // Camera comes up on demand: a mic-first call publishes the video track
        // but doesn't start capture until the toggle is switched on.
        if enabled { CameraPusher.shared.start() }
        videoEnabled = enabled
        applySendState()
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
            if hasVideo { _ = media_live_set_video_enabled(video) }
        }
    }

    /// Observed on the main queue: state (or error text) changed.
    var onState: (() -> Void)?
    /// Decoded peer frames (~10fps), main queue.
    var onFrame: ((UIImage?) -> Void)?

    private let client = DaemonClient()
    private var frameTimer: Timer?
    private var framePath: String?
    private var lastFrameSize = -1

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

    /// Starts a call publishing the selected tracks: session registry entry,
    /// own publish, invite to the peer. `audio`/`video` are the staged stream
    /// set (§3 State 2); both false is rejected by the FFI. The peer's answer
    /// triggers the return leg in handleEnvelope.
    ///
    /// `cameraOn: false` still publishes the video track but sends no frames
    /// until the Bar's camera toggle is switched on — the default for calls
    /// started from the nav bar (mic first).
    func dial(_ peerRef: String, audio: Bool = true, video: Bool = true, cameraOn: Bool = true) {
        guard state == .idle, audio || video else { return }
        audioAvailable = audio
        videoAvailable = video
        audioEnabled = audio
        videoEnabled = video && cameraOn
        peer = peerRef
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
                // Registry entry (parity with core.ts video_call_start); the
                // media itself is FFI-side, not daemon-side.
                let identity = (try? await client.status())?.1 ?? "default"
                let peerBytes = Array(id.utf8.map { AnyEncodable(Int($0)) })
                _ = try await client.request(method: "media.session.start", params: [
                    "identity": AnyEncodable(identity),
                    "peer_bytes": AnyEncodable(peerBytes),
                    "kind": AnyEncodable("live_video"),
                    "mode": AnyEncodable("record"),
                ])
                activateAudioSession()
                if video && cameraOn { CameraPusher.shared.start() }
                let ticket = await ffiString { media_live_start(audio ? 1 : 0, video ? 1 : 0) }
                guard !ticket.isEmpty else {
                    let err = await ffiString { media_live_last_error() }
                    fail(err.isEmpty ? "video start failed" : err)
                    return
                }
                published = true
                applySendState() // a toggle during `.calling` may predate the publish
                try await client.sendText(to: id, LiveInvite.build(action: "start", ticket: ticket, call: true))
                if case .calling = state { notify() } // still waiting for the return leg
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
        pendingInvite = nil
        peer = pending.peer
        state = .inCall
        // The callee always publishes both tracks, but starts mic-only — the
        // Bar turns the camera on.
        audioAvailable = true
        videoAvailable = true
        audioEnabled = true
        videoEnabled = false
        notify()
        Task {
            do {
                activateAudioSession()
                await join(ticket: pending.ticket)
                let own = await ffiString { media_live_start(1, 1) }
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
        state = .idle
        notify()
        // call_stopped mirrors core.ts live_decline so the caller's UI clears.
        Task { try? await client.sendText(to: pending.peer, "call_stopped") }
    }

    func hangUp() {
        terminate(local: true)
    }

    // MARK: - Event routing (called by ChatStore via the main queue)

    /// Handles a call-control message from `peerID`. Invite envelopes and
    /// call control texts are consumed (never shown as chat history).
    func handleEnvelope(peer peerID: String, _ text: String) {
        if text == "call_started" { return } // informational only
        if text == "call_stopped" {
            if state != .idle && activePeer == peerID { terminate(local: false) }
            return
        }
        guard let invite = LiveInvite.parse(text) else { return }
        if invite.isStop {
            if state != .idle && activePeer == peerID { terminate(local: false) }
            return
        }
        guard invite.isStart, invite.isCall, !invite.ticket.isEmpty else { return } // file-share/audio invites: unsupported here
        if state == .calling || state == .inCall {
            // Return leg: the peer answered and is now publishing their
            // camera+mic — join without re-prompting (core.ts return-leg).
            Task { await join(ticket: invite.ticket) }
        } else if state == .idle {
            pendingInvite = (peerID, invite.ticket)
            // Answering publishes both tracks but starts mic-only (camera off
            // until the Bar's toggle), so there is nothing to pre-stage.
            audioAvailable = true
            videoAvailable = true
            state = .incoming
            notify()
        }
    }

    // MARK: - Internals

    /// Subscribes audio (decoded playback through cpal) and video (decoded
    /// frames rewritten to video-frame.jpg).
    private func join(ticket: String) async {
        activateAudioSession()
        let path = await ffiString { media_video_start(ticket) }
        guard !path.isEmpty else {
            fail("video watch failed")
            return
        }
        _ = await Task.detached(priority: .userInitiated) { _ = media_live_subscribe(ticket) }.value
        if state == .idle { return } // hung up while subscribing
        framePath = path
        lastFrameSize = -1
        startFramePolling()
        if state == .calling { state = .inCall }
        notify()
    }

    private func terminate(local: Bool) {
        if local, let peerID = peer {
            Task { try? await client.sendText(to: peerID, LiveInvite.build(action: "stop", ticket: "", call: true)) }
        }
        frameTimer?.invalidate()
        frameTimer = nil
        framePath = nil
        lastFrameSize = -1
        Task.detached(priority: .userInitiated) {
            CameraPusher.shared.stop()
            media_live_stop()
            media_video_stop()
            media_live_unsubscribe()
        }
        state = .idle
        peer = nil
        pendingInvite = nil
        published = false
        audioAvailable = false
        videoAvailable = false
        audioEnabled = false
        videoEnabled = false
        notify()
        onFrame?(nil)
    }

    private func fail(_ message: String) {
        NSLog("idfon video call failed: \(message)")
        lastError = message
        terminate(local: false) // notifies the UI, which surfaces lastError
    }

    /// Rewrites the remote frame into the UI ~10x/s. The FFI renames a new
    /// JPEG over video-frame.jpg atomically; we only reload when the file
    /// size changed (cheap change detection, matches core.ts re-issue).
    private func startFramePolling() {
        frameTimer?.invalidate()
        // Timer fires on the main runloop; hop through the main actor for
        // the MainActor-isolated state (mirrors Calls.swift startFramePolling).
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let path = self.framePath else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? -1
                guard size != self.lastFrameSize, size > 0 else { return }
                self.lastFrameSize = size
                // JPEG decode off the main thread: a 720×1280 decode ~10x/s
                // would otherwise eat main-thread time for the whole call.
                // preparingForDisplay decodes eagerly on the calling thread.
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    let image = UIImage(contentsOfFile: path)?.preparingForDisplay()
                    await MainActor.run { self.onFrame?(image) }
                }
            }
        }
    }

    private func notify() {
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
