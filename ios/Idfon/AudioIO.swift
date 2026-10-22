import AVFAudio

/// A consumer of the single microphone source's raw buffers.
protocol AudioCaptureObserver: AnyObject {
    /// `time` is the tap's capture timestamp, carried so components that need a
    /// sample timeline (the system analyzer) can preserve it.
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

/// A consumer of what the playback bus is about to play — the second ear for
/// the turn-taker (the agent's own voice, so its echo is not mistaken for the
/// caller). Fed at schedule time: the tag timeline is the post timeline (the
/// same stand-in as the tyger relay's TYGER_TAG_LAG_MS).
protocol AudioPlaybackObserver: AnyObject {
    func audioPlayback(_ buffer: AVAudioPCMBuffer)
}

/// The microphone seam. One concrete implementation owns the hardware; tests
/// inject a source that yields synthetic buffers, so consumers never touch an
/// `AVAudioEngine` or the `AVAudioSession`.
protocol AudioSource: AnyObject {
    func addCaptureObserver(_ observer: AudioCaptureObserver)
    func removeCaptureObserver(_ observer: AudioCaptureObserver)
}

/// The playback seam. One concrete implementation owns the output bus; tests
/// inject a sink that records what would have been played.
protocol AudioSink: AnyObject {
    /// Play WAV bytes; returns when playback finishes or is stopped.
    func play(wav: Data) async
    /// Play a PCM buffer; returns when playback finishes or is stopped.
    func play(_ buffer: AVAudioPCMBuffer) async
    /// Play a buffer on repeat until `stopPlayback` (call cues).
    func playLooping(_ buffer: AVAudioPCMBuffer)
    /// Stop whatever is playing and release any waiting `play` call.
    func stopPlayback()
}

/// The app's single microphone source and single playback sink.
///
/// Exactly one `AVAudioEngine`, one input tap, one playback bus, and one
/// `AVAudioSession` configuration exist per process. Capture fans out to
/// observers; every audible thing (TTS, call cues) renders on the playback bus,
/// so that bus is also the echo-cancellation reference. Nothing else may call
/// `installTap`, `setCategory`, or create a playback engine.
///
/// Voice processing stays enabled for the whole run: the AEC filter needs a
/// stable input/output graph, so callers gate by turn, not by toggling the
/// engine (docs/voice-side-channel.md).
final class AudioIO: AudioSource, AudioSink {
    static let shared = AudioIO()

    /// Session/routing profile for the active call.
    enum Profile {
        /// Core-streamed call audio. `.voiceChat` is VPIO's native AEC mode:
        /// remote call audio renders on this engine's playback bus
        /// (`AudioPlaybackSink`), the echo reference (docs/audio-media.md).
        /// (`.default` was tried to avoid VPIO's output-gain drop — it
        /// silently disables echo cancellation, docs/troubleshooting.md.)
        case liveCall
        /// On-device cascade. `.voiceChat` is VPIO's native AEC mode.
        case voiceAgent
        /// Voice-memo recording: play-and-record so review playback shares the
        /// session, `.default` to match the previous recorder config.
        case recording
    }

    private var engine = AVAudioEngine()
    private var playbackPlayer = AVAudioPlayerNode()
    private let observerLock = NSLock()
    private let captureObservers = NSHashTable<AnyObject>.weakObjects()
    private let playbackObservers = NSHashTable<AnyObject>.weakObjects()
    private var profile: Profile?
    private(set) var running = false
    /// True while a queued buffer is playing (cues, TTS). Read by the barge-in
    /// harness; not a public playback state machine.
    private(set) var isPlaying = false
    /// One continuation per queued `play`, so overlapping callers (a cue and a
    /// TTS reply) each resume exactly once instead of clobbering one slot.
    private var pendingPlays: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// One-shots scheduled but not yet finished: a restart must re-arm them or
    /// the audio vanishes silently (the tone-silence regression).
    private var inFlightOneShots: [UUID: AVAudioPCMBuffer] = [:]
    private var sessionObservers: [NSObjectProtocol] = []
    private var restartAfterInterruption = false
    /// The looping cue (ringback/ringtone) currently on the bus, re-armed when
    /// the engine is rebuilt — a restart drops everything scheduled.
    private var activeLoop: AVAudioPCMBuffer?
    /// Engine self-stop recovery (AVAudioEngine.h: a hardware format change
    /// stops the engine and posts AVAudioEngineConfigurationChangeNotification;
    /// nodes stay attached): debounced, capped restarts.
    private var engineObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempts = 0
    /// CallKit session ownership (docs/callkit-integration.md): while a
    /// `call_kit` call runs, CallKit owns `AVAudioSession` — AudioIO starts
    /// capture/playback but never configures or activates the session, and
    /// only after the system hands it over (`didActivate`, the one-way-audio
    /// rule).
    private var callKitOwnsSession = false
    private var callKitActivated = false
    /// Recorded at start: CallKit owned the session for this run.
    private var sessionOwnerIsCallKit = false
    /// A `start` requested before CallKit activated the session.
    private var pendingStart: Profile?
    /// A one-shot play that arrived while the engine waits for CallKit's
    /// `didActivate` (cues drop silently otherwise, #50).
    private var pendingOneShot: AVAudioPCMBuffer?

    private init() {}

    /// Wired/USB headset route (docs/stereo-calls.md): stereo call capture is
    /// allowed, and the headset already attenuates the echo path — so the
    /// engine skips voice processing here, which is what keeps the tap at the
    /// device's channel count. Speaker and Bluetooth routes keep VPIO mono.
    static func stereoCaptureAllowed() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            output.portType == .headphones || output.portType == .usbAudio
        }
    }

    /// The call audio mode picked on the live panel's media group (nil = the
    /// auto rule above). Drives the VPIO decision, the session mode, and the
    /// capture channel count (docs/stereo-calls.md).
    static var preferredMode: CallAudioMode?

    /// Stereo capture: the picked mode, or on auto the headset route.
    static func stereoCaptureForCall() -> Bool {
        if let preferredMode { return preferredMode == .earphone2D }
        return stereoCaptureAllowed()
    }

    /// The channel count the call's mic leg publishes.
    static func captureChannelsForCall() -> Int { stereoCaptureForCall() ? 2 : 1 }

    // MARK: - lifecycle

    /// Configure the session and start the one engine. Idempotent per profile;
    /// a different profile restarts it. Main thread.
    func start(profile: Profile) {
        runOnAudio { [self] in
            if callKitOwnsSession, !callKitActivated {
                pendingStart = profile
                Automation.mark("audio: start deferred until callkit didActivate profile=\(profile)")
                return
            }
            sessionOwnerIsCallKit = callKitOwnsSession
            Automation.mark("audio: mic permission=\(AVAudioApplication.shared.recordPermission)")
            AVAudioApplication.requestRecordPermission { granted in
                // The engine start below can fail while the mic answer is
                // still pending; retry on a grant. Still the one engine —
                // `startEngine` rebuilds the same single graph, never a second.
                guard granted else {
                    Automation.mark("audio: mic permission denied")
                    return
                }
                self.runOnAudio {
                    guard self.profile == profile, !self.running else { return }
                    Automation.mark("audio: retrying engine start after mic grant")
                    self.startEngine()
                }
            }
            if running, self.profile == profile { return }
            if running || self.profile != nil { stopLocked() }
            self.profile = profile
            restartAfterInterruption = false
            restartAttempts = 0
            restartWorkItem?.cancel()
            // Observers BEFORE configuration: setActive/override can begin an
            // interruption synchronously, and a missed `.began` leaves
            // `restartAfterInterruption` false — the engine then dies at the
            // start of every call and is never restarted (mute call).
            // CallKit owns interruptions for its own session (#49): our
            // restart logic would race didDeactivate/didActivate.
            if !sessionOwnerIsCallKit { installSessionObservers() }
            configureSession(profile)
            startEngine()
        }
    }

    /// Stop capture and playback and deactivate the session.
    func stop() {
        runOnAudio { [self] in stopLocked() }
    }

    /// CallKit is taking over the session for a call (before the report).
    ///
    /// Configure the session now, on the inactive session — Apple's CallKit
    /// checklist: the app sets `PlayAndRecord` + `VoiceChat`, CallKit does the
    /// activation. Left unset, the system can hand back a session that is not
    /// a voice session and the AEC tuning is wrong on the speakerphone path
    /// (docs/callkit-integration.md §6). Never *activate* here: starting audio
    /// before `didActivate` is the documented one-way-audio bug.
    func callKitWillStart() {
        runOnAudio { [self] in
            callKitOwnsSession = true
            callKitActivated = false
            applyVoiceSessionConfig()
            markOutput("output at callkit willStart")
        }
    }

    /// The system activated the session: run any deferred start now.
    func callKitDidActivate() {
        runOnAudio { [self] in
            callKitActivated = true
            // The pre-report config was ours; activation is the system's —
            // log what CallKit actually activated so a device check can
            // confirm the voice session survived (or show what replaced it).
            markOutput("output at callkit didActivate")
            guard let pending = pendingStart else { return }
            pendingStart = nil
            Automation.mark("audio: callkit didActivate — starting deferred profile=\(pending)")
            start(profile: pending)
            if let one = pendingOneShot {
                pendingOneShot = nil
                Task { await AudioIO.shared.play(one) }
            }
        }
    }

    /// The CallKit call ended (or was refused): session control returns to the app.
    func callKitDidEnd() {
        runOnAudio { [self] in
            callKitOwnsSession = false
            callKitActivated = false
            pendingStart = nil
            pendingOneShot = nil
        }
    }

    private func stopLocked() {
        pendingStart = nil
        pendingOneShot = nil
        guard running || profile != nil else { return }
        stopEngine()
        removeSessionObservers()
        profile = nil
        if sessionOwnerIsCallKit {
            // CallKit deactivates its own session.
            Automation.mark("audio: stopped (callkit session left alone)")
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            Automation.mark("audio: stopped")
        }
    }

    private func startEngine() {
        // Fresh engine + player per start: a node cannot be re-attached to a
        // rebuilt graph, and voice processing must be enabled before the
        // playback bus is connected.
        engine = AVAudioEngine()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        // The documented self-stop signal; object-scoped to this engine.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineConfigurationChanged() }
        playbackPlayer = AVAudioPlayerNode()
        engine.attach(playbackPlayer)
        let input = engine.inputNode
        // Order matters: enable voice processing while the engine is stopped,
        // then connect the playback bus. Connecting first materializes the
        // output graph at the pre-VPIO format and `setVoiceProcessingEnabled`
        // raises an ObjC exception Swift cannot catch (docs/troubleshooting.md,
        // "SIGABRT"). Skipped entirely on the stereo (headset) route — see
        // `stereoCaptureAllowed`.
        if Self.stereoCaptureForCall() {
            Automation.mark("audio: voice-processing skipped (headset route, stereo capture)")
        } else {
            do {
                try input.setVoiceProcessingEnabled(true)
                Automation.mark("audio: voice-processing enabled profile=\(String(describing: profile))")
            } catch {
                Automation.mark("audio: voice-processing unsupported: \(error.localizedDescription)")
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        engine.connect(playbackPlayer, to: engine.mainMixerNode, format: nil)

        input.removeTap(onBus: 0) // insurance: installTap aborts if one survived
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, time in
            self?.fanOut(buffer, at: time)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            Automation.mark("audio: started profile=\(String(describing: profile))")
            markOutput("output at start")
            // Re-arm what the rebuild dropped (the ring must not die with one
            // interruption; a dropped one-shot resumes its caller silently).
            rearmPlayback()
        } catch {
            // Marker as well as os_log error: every later cue/TTS drop is a
            // consequence of this, and console captures must show the cause.
            Automation.mark("audio: engine start FAILED \(error.localizedDescription)")
            idfonError("idfon audio: engine start failed: \(error.localizedDescription)")
            // A dead engine is total call silence (tones, TTS, recognition) —
            // never fail mute again.
            CallFeedback.post("Audio unavailable: \(error.localizedDescription)")
        }
    }

    /// The engine stopped itself (hardware format change; AVAudioEngine.h).
    private func engineConfigurationChanged() {
        Automation.mark("audio: engine configuration changed running=\(engine.isRunning)")
        if profile != nil, !engine.isRunning { scheduleRestart() }
    }

    private func stopEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        playbackPlayer.stop()
        isPlaying = false
        resumePendingPlays()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }

    private func configureSession(_ profile: Profile) {
        if sessionOwnerIsCallKit {
            // CallKit's activated session is in control (category, route,
            // activation): the category/mode were set on the inactive session
            // in `callKitWillStart`; configuring or activating here is the
            // one-way-audio bug.
            Automation.mark("audio: session owned by callkit — not configuring")
            return
        }
        let session = AVAudioSession.sharedInstance()
        switch profile {
        case .liveCall:
            applyVoiceSessionConfig()
        case .voiceAgent:
            try? session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP])
        case .recording:
            try? session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker])
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            // Swallowed before: a dead session yields an engine that halts
            // within a beat and a mute call that logs like a healthy one.
            Automation.mark("audio: setActive FAILED \(error.localizedDescription)")
        }
        // With an explicit audio mode the panel owns the route; on auto, force
        // the speaker only on the handset/speaker path.
        if Self.preferredMode == nil, !Self.stereoCaptureAllowed() {
            try? session.overrideOutputAudioPort(.speaker)
        }
        Automation.mark(
            "audio: session category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
        )
    }

    /// The voice-call session shape: `.playAndRecord` + `.voiceChat` (VPIO's
    /// AEC mode) with the speaker default. On the stereo (headset) route the
    /// mode is `.default`: `.voiceChat` would re-apply the voice tuning (and
    /// its mono bias) that the VPIO skip just avoided (docs/stereo-calls.md).
    /// Set on the *inactive* session; activation belongs to the owner — the
    /// app on the Bar path, CallKit on `call_kit` channels (where this runs
    /// before the report).
    private func applyVoiceSessionConfig() {
        let session = AVAudioSession.sharedInstance()
        // Set the mode in the category call; move the route override last
        // (setMode(.voiceChat) after the override re-evaluates the route).
        try? session.setCategory(
            .playAndRecord, mode: Self.stereoCaptureForCall() ? .default : .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setPreferredIOBufferDuration(0.01)
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in self?.handleRouteChange(note) })
    }

    private func removeSessionObservers() {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if value == AVAudioSession.InterruptionType.began.rawValue {
            Automation.mark("audio: interruption began running=\(running)")
            restartAfterInterruption = running
            if running { stopEngine() }
        } else if value == AVAudioSession.InterruptionType.ended.rawValue {
            // Self-heal: restart whenever a profile is active and the engine is
            // down, even if the `.began` was missed.
            let restart = restartAfterInterruption || (profile != nil && !running)
            restartAfterInterruption = false
            Automation.mark("audio: interruption ended restart=\(restart)")
            if restart {
                // Interruptions tear the tap down at `.began`, so recovery is a
                // full rebuild; reactivate the session first (the documented
                // interruption-end step).
                try? AVAudioSession.sharedInstance().setActive(true)
                startEngine()
            }
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            Automation.mark("audio: route lost (old device unavailable) — engine stopped")
            stopEngine()
        }
        // The engine stopped itself on a hardware format change (AVAudioEngine.h:
        // "the engine stops itself … nodes remain attached"); the graph is
        // intact, so recovery is a debounced restart — never a rebuild from
        // inside a notification callback (documented deadlock), and never a
        // rebuild at all here: re-enabling voice processing posts more session
        // churn (observed runaway that froze the app).
        if profile != nil, !engine.isRunning { scheduleRestart() }
    }

    /// Debounced, capped engine recovery (debounce coalesces the session churn
    /// that accompanies every configuration change).
    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restartEngine() }
        restartWorkItem = item
        Self.queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// `running == true`: the engine stopped itself with the graph intact —
    /// plain `start()` and re-arm the looping cue. `running == false`: we tore
    /// the tap down, so a full rebuild. Capped per activation so a hopeless
    /// session cannot spin.
    private func restartEngine() {
        guard profile != nil, !engine.isRunning else { return }
        guard restartAttempts < 3 else {
            Automation.mark("audio: engine restart gave up after \(restartAttempts) attempts")
            return
        }
        restartAttempts += 1
        Automation.mark("audio: engine halted — recovery #\(restartAttempts) full=\(!running)")
        guard running else {
            startEngine()
            return
        }
        do {
            try engine.start()
            playbackPlayer.stop()
            // Re-arm everything the stop dropped (loop AND one-shots) instead
            // of resuming the callers silently.
            rearmPlayback()
        } catch {
            Automation.mark("audio: engine restart FAILED \(error.localizedDescription)")
        }
    }

    // MARK: - capture (AudioSource)

    func addCaptureObserver(_ observer: AudioCaptureObserver) {
        runOnAudio { [self] in
            observerLock.lock()
            captureObservers.add(observer as AnyObject)
            observerLock.unlock()
        }
    }

    func removeCaptureObserver(_ observer: AudioCaptureObserver) {
        runOnAudio { [self] in
            observerLock.lock()
            captureObservers.remove(observer as AnyObject)
            observerLock.unlock()
        }
    }

    /// Copy the list under the lock, then call outside it: an observer must not
    /// be able to deadlock the audio thread.
    private func fanOut(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        observerLock.lock()
        let observers = captureObservers.allObjects
        observerLock.unlock()
        for observer in observers {
            (observer as? AudioCaptureObserver)?.audioCapture(buffer, at: time)
        }
    }

    // MARK: - playback observers (the second ear)

    func addPlaybackObserver(_ observer: AudioPlaybackObserver) {
        runOnAudio { [self] in
            observerLock.lock()
            playbackObservers.add(observer as AnyObject)
            observerLock.unlock()
        }
    }

    func removePlaybackObserver(_ observer: AudioPlaybackObserver) {
        runOnAudio { [self] in
            observerLock.lock()
            playbackObservers.remove(observer as AnyObject)
            observerLock.unlock()
        }
    }

    /// Copy-under-lock, call outside it (an observer must not deadlock the audio thread).
    private func fanOutPlayback(_ buffer: AVAudioPCMBuffer) {
        observerLock.lock()
        let observers = playbackObservers.allObjects
        observerLock.unlock()
        for observer in observers {
            (observer as? AudioPlaybackObserver)?.audioPlayback(buffer)
        }
    }

    // MARK: - playback (AudioSink)

    func play(wav: Data) async {
        // A dropped play is silent by design (no crash on a dead bus), so it
        // must leave a marker: "no tone / no TTS" triage reads these lines.
        guard running else {
            Automation.mark("audio: wav play dropped engine idle")
            return
        }
        guard let buffer = Self.buffer(wav: wav, target: playbackPlayer.outputFormat(forBus: 0))
        else {
            Automation.mark("audio: wav play dropped decode failed")
            return
        }
        await play(buffer)
    }

    func play(_ buffer: AVAudioPCMBuffer) async {
        guard running else {
            if pendingStart != nil {
                // The engine waits for CallKit's didActivate: keep the cue and
                // play it when the engine comes up (#50).
                pendingOneShot = buffer
                Automation.mark("audio: play deferred until callkit didActivate")
            } else {
                Automation.mark("audio: play dropped engine idle")
            }
            return
        }
        guard let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0))
        else {
            Automation.mark("audio: play dropped convert failed in=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch out=\(playbackPlayer.outputFormat(forBus: 0).sampleRate)Hz/\(playbackPlayer.outputFormat(forBus: 0).channelCount)ch")
            return
        }
        let id = UUID()
        fanOutPlayback(converted) // the second ear: what the bus is about to play
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingPlays[id] = continuation
            inFlightOneShots[id] = converted
            isPlaying = true
            playbackPlayer.scheduleBuffer(
                converted, at: nil, options: [], completionCallbackType: .dataPlayedBack
            ) { _ in
                // via .shared: captures no self in the @Sendable hop
                Self.queue.async { AudioIO.shared.finishPlay(id) }
            }
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    /// Resume exactly once per play: whichever of stop/flush or the completion
    /// callback arrives first wins; the other finds nothing.
    /// Re-schedule what a restart dropped: `playbackPlayer.stop()` (or a fresh
    /// player in a rebuild) discards scheduled buffers. The loop and in-flight
    /// one-shots re-arm; their callers resume when the re-armed audio finishes.
    private func rearmPlayback() {
        if let loop = activeLoop {
            playbackPlayer.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
            Automation.mark("audio: loop re-armed after engine restart")
        }
        for (id, buffer) in inFlightOneShots {
            playbackPlayer.scheduleBuffer(
                buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
            ) { _ in
                Self.queue.async { AudioIO.shared.finishPlay(id) }
            }
            Automation.mark("audio: one-shot re-armed after engine restart")
        }
        if (activeLoop != nil || !inFlightOneShots.isEmpty), !playbackPlayer.isPlaying {
            playbackPlayer.play()
        }
    }

    private func finishPlay(_ id: UUID) {
        isPlaying = false
        inFlightOneShots.removeValue(forKey: id)
        pendingPlays.removeValue(forKey: id)?.resume()
    }

    private func resumePendingPlays() {
        let pending = pendingPlays
        pendingPlays.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    /// Schedule one stream chunk (remote call audio from the media playback
    /// callback) without awaiting: chunks queue back to back on the playback
    /// bus and must never wait on a previous chunk's completion callback.
    /// This bus is the AEC reference — remote audio anywhere else cannot be
    /// echo-cancelled (docs/audio-media.md).
    func playStream(_ buffer: AVAudioPCMBuffer) {
        runOnAudio { [self] in
            guard running else {
                Automation.mark("audio: stream play dropped engine idle")
                return
            }
            guard let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0))
            else {
                Automation.mark("audio: stream play dropped convert failed")
                return
            }
            fanOutPlayback(converted) // the second ear
            playbackPlayer.scheduleBuffer(converted, at: nil, options: [], completionHandler: nil)
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    func playLooping(_ buffer: AVAudioPCMBuffer) {
        guard running else {
            // Engine not up yet (CallKit deferred start): stash the loop —
            // `startEngine` re-arms it exactly like an engine restart.
            if let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0)) {
                activeLoop = converted
                isPlaying = true
                Automation.mark("audio: loop play deferred engine idle")
            } else {
                Automation.mark("audio: loop play dropped engine idle")
            }
            return
        }
        guard let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0))
        else {
            Automation.mark("audio: loop play dropped convert failed in=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch")
            return
        }
        playbackPlayer.scheduleBuffer(converted, at: nil, options: [.loops], completionHandler: nil)
        fanOutPlayback(converted) // the second ear (a looping ring: fed once)
        activeLoop = converted
        isPlaying = true
        if !playbackPlayer.isPlaying { playbackPlayer.play() }
        // The ring is the canary: prove the loop was real (non-silent PCM) and
        // that the engine actually rendered it — a scheduled-but-never-rendered
        // buffer logs exactly like a played one otherwise.
        Automation.mark(
            "audio: loop scheduled frames=\(converted.frameLength) rms=\(String(format: "%.4f", Self.rms(converted))) fmt=\(converted.format.sampleRate)Hz/\(converted.format.channelCount)ch")
        markOutput("output at ring")
        Self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // nil lastRenderTime = the node never rendered at all.
            let clock = self.playbackPlayer.lastRenderTime.flatMap {
                self.playbackPlayer.playerTime(forNodeTime: $0)
            }
            Automation.mark(
                "audio: loop check sampleTime=\(clock.map { String($0.sampleTime) } ?? "nil") playing=\(self.playbackPlayer.isPlaying) engine=\(self.engine.isRunning)")
        }
    }

    func stopPlayback() {
        playbackPlayer.stop()
        activeLoop = nil
        isPlaying = false
        resumePendingPlays()
    }

    // MARK: - PCM helpers

    /// One marker line with the session's output reality: route, system volume,
    /// category and mode — "played per the log" is only worth something next to
    /// what the hardware was set to.
    private func markOutput(_ tag: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: ",")
        Automation.mark(
            "audio: \(tag) outputs=[\(outputs)] volume=\(session.outputVolume) category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
    }

    /// Mean amplitude of the buffer's first channel; -1 when the format has no
    /// accessible float channel (verification marker only).
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return -1 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    /// Decode WAV and convert to `target`. `nil` on any decode error.
    static func buffer(wav: Data, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idfon-audioio.wav")
        guard (try? wav.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil
        else { return nil }
        return convert(input, to: target)
    }

    /// Convert `buffer` to `target`; returns it unchanged when it already matches.
    static func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == target.channelCount,
           buffer.format.commonFormat == target.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        // One second of headroom so the converter's output buffer never fills.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            + AVAudioFrameCount(target.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return output
    }

    /// Engine/session work serializes here — never on the main actor. The
    /// session activation and engine start/stop can block for seconds (and on
    /// a cold wake indefinitely: the #61 wedge froze main inside the ring's
    /// audio start and the app stopped handling pushes mid-handler). Same
    /// one-engine discipline as before, just off-main.
    private static let queue = DispatchQueue(label: "idfon.audio-io")

    private func runOnAudio(_ block: @escaping () -> Void) {
        Self.queue.async(execute: block)
    }
}