import AVFAudio
import Foundation

/// A1 client-side voice agent loop: on-device STT -> text turn to the agent
/// peer -> await the reply -> on-device TTS. This is the cascade the holder
/// side-channel replaces GPT-Live with; the app owns all audio.
///
/// One long-lived analyzer stays prepared for the whole session; the mic tap
/// stays live while the agent speaks so the caller can barge in (AEC cancels
/// the agent's own TTS). `VoicePromptSegmenter` picks utterance boundaries: a
/// final result commits immediately, a 1.2 s no-change gap is the fallback.
/// iOS 26+ uses the SpeechAnalyzer; older iOS falls back to a per-turn
/// SFSpeechRecognizer.
///
/// UI drives `start`/`stop`; `run`/`runText` are launch-arg automations.
@MainActor
final class VoiceAgentSession: NSObject {
    static let shared = VoiceAgentSession()

    enum State: Equatable {
        case idle
        case listening(String)
        case thinking
        case speaking(String)
    }

    private let voice = OnDeviceVoice.shared
    /// Reply speech backend; resolved per contact at `start` (else the global
    /// default: Apple fallback, Kokoro opt-in via `IDFON_TTS`).
    private var tts: TtsEngine = SpeechEngines.tts
    private var ttsBackend = SpeechEngines.backend
    /// Recognizer backend; resolved per contact at `start`.
    private var asrBackend = SpeechEngines.asrBackend
    private let segmenter = VoicePromptSegmenter()
    private var asr: (any AsrEngine)?

    private(set) var isActive = false
    /// Peer this voice call is with, so the shared call UI can title it.
    private(set) var activePeerId: String?
    /// The resolved peer id of the called agent, for director forwarding.
    private var agentPeerId: String?
    /// Set when the call is to an on-device agent: answers come from AFM, not a
    /// peer, and no dial happens.
    private var localAgent: OnDeviceAgent?
    /// Latest state, readable by the call UI (the `onState` callback is single-
    /// owner, so the LiveActivityController owns it).
    private(set) var state: State = .idle
    /// Shadow turn-taker (decision-log diff only; see TurnShadow).
    nonisolated(unsafe) private var turnShadow: TurnShadow?
    /// One-line live model/latency readout for the call bar, e.g.
    /// "Whistle 100 ms · Kokoro 0.7 s".
    private(set) var stats: String?
    /// Capture->final time of the last turn, used when the engine streams
    /// without a discrete transcribe step.
    private var lastListenMs = 0
    var onState: ((State) -> Void)?
    /// Mic gate, driven by the call UI's mute button.
    private var micMuted = false

    nonisolated(unsafe) private var stopRequested = false
    private var turnLimit = Int.max
    private var turnsDone = 0
    /// Consecutive silent turns; a call is only dropped after several.
    private var noSpeechTurns = 0
    /// True once the "are you still there?" check-in has been spoken this call.
    private var silencePrompted = false
    /// Identifier for this call, scoping the spoken-turn transcripts.
    private var callId = UUID().uuidString
    /// Optional reference sentence (`IDFON_ASR_REF` / `-asrref`) for an A/B
    /// WER readout of the active recognizer.
    private var asrReference: String?
    private var client = IdfonClient()
    private var promptWaiter: CheckedContinuation<String?, Never>?
    /// The call setup task, cancelled on hang-up so a slow recognizer/TTS load
    /// cannot keep the call alive.
    private var setupTask: Task<Void, Never>?
    /// User's loudspeaker preference for this call; the route guard re-asserts
    /// it after VPIO or a route change drops the route to the receiver.
    private var preferSpeaker = true
    private var routeObserver: NSObjectProtocol?
    /// Last text spoken by TTS, so the agent's own tail can be dropped instead
    /// of re-sent as a user turn (self-bleed).
    private var lastSpoken: String?
    /// Voice feedback ("mm-hm") that played and when: it never enters history
    /// (`lastSpoken` stays the agent's reply) and is only echo-checked near its
    /// playback window, so a later real "mm-hm" can still be a turn.
    private var lastFeedback: String?
    private var lastFeedbackAt: Date?
    /// In-flight feedback utterance; drained before a reply speaks.
    private var feedbackTask: Task<Void, Never>?
    /// True while the agent speaks and the recognizer is armed for barge-in;
    /// a committed utterance then cancels playback instead of ending a turn.
    private var bargeInArmed = false
    /// Text that cancelled playback, consumed by `speak`.
    private var bargeInHeard: String?
    /// Barge-in text handed to the next turn instead of listening again.
    private var pendingHeard: String?

    /// Continuous conversation until `stop()`.
    /// Talk to an on-device agent: no peer, no dial; turns run on AFM.
    func runOnDevice(agent: OnDeviceAgent, turns: Int = Int.max) {
        start(peerRef: agent.peerId, turns: turns, agent: agent)
    }

    func start(peerRef: String, turns: Int = Int.max, agent: OnDeviceAgent? = nil) {
        Automation.mark("voice-agent: start requested ref=\(peerRef) active=\(isActive)")
        guard !isActive else {
            Automation.mark("voice-agent: start IGNORED — session already active")
            return
        }
        isActive = true
        localAgent = agent
        stopRequested = false
        callId = UUID().uuidString
        turnLimit = turns
        turnsDone = 0
        activePeerId = peerRef
        micMuted = false
        asrReference = ProcessInfo.processInfo.environment["IDFON_ASR_REF"] ?? Self.launchString("-asrref")
        configureSession()
        SpeechEngines.prewarm()
        segmenter.onPartial = { [weak self] text in
            guard let self, !self.bargeInArmed else { return }
            self.setState(.listening(text))
            // Live bubble: the caller's own words appear in the chat as the
            // recognizer produces them, then are replaced on commit.
            if let peerId = self.agentPeerId, !text.isEmpty {
                self.recordCallerTurn(peerId: peerId, text: text, final: false)
            }
        }
        segmenter.onCommit = { [weak self] text in self?.handleCommit(text) }
        segmenter.start()
        setupTask = Task { @MainActor in
            let peer: Peer
            if let localAgent {
                peer = localAgent.peer
            } else {
                let peers = (try? await client.peers()) ?? []
                guard !stopRequested else { finish(); return }
                guard let resolved = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                    Automation.mark("voice-agent: FAIL no peer \(peerRef)")
                    CallFeedback.post("No voice call available for this contact.")
                    finish()
                    return
                }
                peer = resolved
            }
            agentPeerId = peer.id
            Automation.mark("voice-agent: start peer=\(peer.id)")
            if localAgent == nil {
                // Reset the model history before a new call: the session log is
                // the medium, never the model's context (docs/session-context.md).
                // Sent early; the engine prep and greeting that follow give the
                // clear time to land.
                _ = try? await client.sendText(to: peer.id, "IDFON-SESSION/1\naction=rotate")
            }
            guard !stopRequested else { finish(); return }
            // Per-contact on-device engines (else the app defaults). Resolved
            // here, once the peer id is known, before the recognizer is built.
            ttsBackend = ContactOnDeviceEngines.tts(for: peer.id).flatMap(TtsBackend.init(rawValue:)) ?? SpeechEngines.backend
            tts = SpeechEngines.makeTts(ttsBackend)
            asrBackend = ContactOnDeviceEngines.asr(for: peer.id).flatMap(AsrBackend.init(rawValue:)) ?? SpeechEngines.asrBackend
            setState(.listening(""))
            // A recognizer may need a first-run download/CoreML compile;
            // block the turn loop until it is ready so the first listen does
            // not time out against a still-loading model.
            await startAnalyzer()
            guard !stopRequested else { finish(); return }
            // Enabling voice processing re-evaluates the output route and can
            // drop `.voiceChat` back to the receiver; re-assert the loudspeaker.
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            // TTS renders on the app's single playback bus (`AudioIO`), the AEC
            // reference for capture.
            tts.playback = AudioIO.shared
            // Load the reply voice and fetch the greeting while ringback still
            // plays, so "answered" is followed immediately by speech instead
            // of dead air waiting on the model or the agent.
            await tts.prepare()
            guard !stopRequested else { finish(); return }
            // Let ChatStore finish hydrating so the reply snapshot excludes
            // pre-existing history.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !stopRequested else { finish(); return }
            // On-device director: load + warm the AFM session during call setup,
            // hidden behind the ringback. Runs when this contact is set to proxy
            // mode (`-directorcall` forces it for a probe). An on-device agent
            // uses `OnDeviceAgentRunner` instead.
            if localAgent == nil {
                await DirectorRuntime.shared.startCall(
                    proxy: ContactVoiceTurnModes.mode(for: peer.id) == .proxy)
            }
            guard !stopRequested else { finish(); return }
            var greeting: (display: String, spoken: String)?
            if !stopRequested {
                let greetTurn =
                    "The caller just connected on a voice call. Greet them briefly and invite them to speak."
                // Proxy mode greets through the agent (so the caller never
                // hears a "voice director" persona). On-device mode greets
                // locally, and passive mode has no director at all.
                if localAgent != nil {
                    // On-device agent: greet locally. Proxy and passive greet
                    // through the agent.
                    greeting = await reply(
                        peerId: peer.id,
                        text: greetTurn,
                        logPrefix: "voice-agent-greet",
                        spokenTurnId: "\(callId)-greet"
                    )
                } else {
                    greeting = await sendAndAwait(
                        peerId: peer.id,
                        text: greetTurn,
                        logPrefix: "voice-agent-greet",
                        spokenTurnId: "\(callId)-greet"
                    )
                }
            }
            // The line is answered only once the agent is about to speak, so the
            // cue has no gap after it.
            if !stopRequested { CallTonePlayer.shared.start(.answered) }
            if let greeting, !greeting.spoken.isEmpty, !stopRequested {
                setState(.speaking(greeting.spoken))
                _ = await speak(greeting.spoken)
                updateStats()
            }
            while !stopRequested && turnsDone < turnLimit {
                guard await performTurn(peerId: peer.id) else { break }
            }
            Automation.mark("voice-agent: done")
            finish()
        }
    }

    func stop() {
        Automation.mark("voice-agent: stop requested active=\(isActive)")
        stopRequested = true
        // Cancel setup and speech now; otherwise hang-up waits out a recognizer
        // download / TTS load and the ringback keeps playing until the setup
        // task finally observes `stopRequested`.
        setupTask?.cancel()
        setupTask = nil
        tts.stop()
        deliver(nil)
        finish()
    }

    /// One-shot automation (`-voiceagent <ref> [turns]`).
    func run(peerRef: String, turns: Int) {
        start(peerRef: peerRef, turns: turns)
    }

    /// Text-driven verification (`-voiceagenttext <ref> <text>`).
    func runText(peerRef: String, text: String) {
        configureSession()
        Task { @MainActor in
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent-text: FAIL no peer \(peerRef)")
                return
            }
            Automation.mark("voice-agent-text: start peer=\(peer.id) text=\(text)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let result = await sendAndAwait(peerId: peer.id, text: text, logPrefix: "voice-agent-text")
            else { return }
            Automation.mark("voice-agent-text: reply=\(result.display)")
            if !result.spoken.isEmpty { _ = await speak(result.spoken) }
            Automation.mark("voice-agent-text: done")
        }
    }

    // MARK: - turn

    /// The caller's own turn in the chat: written live from the recognizer's
    /// partials ("speaking…"), then again when the turn commits with the final,
    /// possibly corrected, text.
    private func recordCallerTurn(peerId: String, text: String, final: Bool) {
        ChatStore.shared.recordSpokenTurn(
            peerId: peerId, callId: callId, turnId: "\(callId)-\(turnsDone)-user",
            role: "caller", text: text, final: final
        )
    }

    /// Drop the live caller bubble for a turn that produced nothing to send.
    private func dropCallerTurn(peerId: String) {
        ChatStore.shared.removeSpokenTurn(peerId: peerId, turnId: "\(callId)-\(turnsDone)-user")
    }

    private func performTurn(peerId: String) async -> Bool {
        turnsDone += 1
        let turnStart = Date()
        var heard: String? = pendingHeard
        pendingHeard = nil
        // Retry within the turn when the recognizer catches the agent's own TTS
        // tail; only a transcript that is not the last spoken reply is sent.
        if heard == nil {
            for _ in 0..<3 {
                setState(.listening(""))
                let listenStart = Date()
                guard let text = await listenOnce(), !text.isEmpty else { break }
                lastListenMs = Int(Date().timeIntervalSince(listenStart) * 1000)
                Automation.mark("voice-agent: asr backend=\(asr?.name ?? "sfspeech") listen_ms=\(lastListenMs)")
                if let spoken = lastSpoken, !spoken.isEmpty,
                   voice.isEcho(spoken: spoken, heard: text) {
                    Automation.mark("voice-agent: dropped echo heard=\(text)")
                    dropCallerTurn(peerId: peerId)
                    continue
                }
                // Optional on-device LM cleanup (fail-open to the raw transcript).
                let corrected = await SpeechCorrection.correct(text)
                if corrected != text {
                    Automation.mark("voice-agent: corrected=\(corrected)")
                }
                heard = corrected
                break
            }
        }
        guard var heard, !heard.isEmpty else {
            dropCallerTurn(peerId: peerId)
            noSpeechTurns += 1
            Automation.mark("voice-agent: no transcript turn=\(turnsDone) streak=\(noSpeechTurns)")
            // Check in once before ending: silence is not a hangup. Then give
            // the caller a few more chances to answer.
            if !silencePrompted, noSpeechTurns >= 2, !stopRequested {
                silencePrompted = true
                setState(.speaking("Are you still there?"))
                if let bargeIn = await speak("Are you still there?") { pendingHeard = bargeIn }
                setState(.idle)
                return true
            }
            return noSpeechTurns < 5
        }
        noSpeechTurns = 0
        silencePrompted = false
        Automation.mark("turn-taker: \(TurnTakerSetting.usesModel(for: activePeerId, modelAvailable: turnShadow != nil) ? "tyger" : "classic")")
        Automation.mark("voice-agent: heard=\(heard)")
        if let asrReference, !asrReference.isEmpty {
            let wer = AsrScore.wer(reference: asrReference, hypothesis: heard)
            Automation.mark("voice-agent: wer=\(String(format: "%.3f", wer)) backend=\(asr?.name ?? "sfspeech") ref=\"\(asrReference)\" heard=\"\(heard)\"")
        }
        // Self-bleed: the recognizer may re-hear the tail of the agent's own
        // speech at the start of this turn. Drop it so the agent is not
        // addressed by, or asked about, its own words.
        let withoutEcho = EchoTrim.trim(heard: heard, lastSpoken: lastSpoken)
        if withoutEcho != heard {
            Automation.mark("voice-agent: echo trimmed heard=\(heard) -> \(withoutEcho.isEmpty ? "<empty>" : withoutEcho)")
            heard = withoutEcho
        }
        if heard.isEmpty {
            dropCallerTurn(peerId: peerId)
            setState(.listening(""))
            return true
        }
        // Deterministic turn policy (prototype): a pure backchannel is not a
        // request, so do not spend an agent turn on it. Fail-open: anything
        // unclear is forwarded. Enabled with `-turncontroller`.
        if ProcessInfo.processInfo.arguments.contains("-turncontroller"),
           TurnController.decide(transcript: heard) == .ignoreBackchannel {
            Automation.mark("voice-agent: backchannel ignored heard=\(heard)")
            dropCallerTurn(peerId: peerId)
            setState(.listening(""))
            return true
        }
        // Show the caller's spoken turn in the chat, not just the agent's reply.
        recordCallerTurn(peerId: peerId, text: heard, final: true)
        setState(.thinking)
        let replyStart = Date()
        guard let result = await reply(
            peerId: peerId, text: heard, logPrefix: "voice-agent",
            spokenTurnId: "\(callId)-\(turnsDone)-agent"
        )
        else {
            // A missing reply must not kill the call; try the next turn.
            Automation.mark("voice-agent: no reply, continuing")
            return true
        }
        let replyMs = Int(Date().timeIntervalSince(replyStart) * 1000)
        Automation.mark("voice-agent: reply=\(result.display)")
        var speakMs = 0
        if !result.spoken.isEmpty {
            setState(.speaking(result.spoken))
            let speakStart = Date()
            pendingHeard = await speak(result.spoken)
            speakMs = Int(Date().timeIntervalSince(speakStart) * 1000)
        }
        // Turn-stage timings for the latency report (docs/benchmarks.md):
        // asr_gap_ms = turn-detection wait, reply_ms = network + agent turn,
        // speak_ms = TTS + playback (includes speak()'s post-roll hold).
        Automation.mark(
            "voice-agent: turn=\(turnsDone) asr_gap_ms=\(segmenter.lastCommitGapMs) listen_ms=\(lastListenMs) reply_ms=\(replyMs) speak_ms=\(speakMs) total_ms=\(Int(Date().timeIntervalSince(turnStart) * 1000))"
        )
        updateStats()
        setState(.idle)
        return turnsDone < turnLimit
    }

    /// Per-turn caller context pushed with every transcript: the client-cascade
    /// speech engines actually in use, so the agent answers from the live state
    /// instead of its own configured pipeline (which can name a different
    /// holder route). Injected as untrusted data, never instructions.
    private var callContext: String {
        "Client cascade (on-device speech). Recognition: \(asrBackend.title); Generation: \(ttsBackend.title). The holder only produces text."
    }

    /// Forward one turn to the called agent and return its reply text (the
    /// director's `voice_forward`). No chat bookkeeping; the director speaks
    /// the reply. Called from the director's background thread via a callback.
    func forwardToActiveAgent(_ text: String) async -> String? {
        guard let peerId = agentPeerId else {
            Automation.mark("director: forward FAIL no peer")
            return nil
        }
        guard let message = await sendAndMatchReply(
            peerId: peerId, text: text, turnId: "\(callId)-fwd\(turnsDone)",
            logPrefix: "director: forward"),
              case .text(let raw) = message.kind else {
            Automation.mark("director: forward FAIL no reply")
            return nil
        }
        let spoken = Self.spokenText(from: raw)
        let reply = spoken.isEmpty ? Self.stripEnvelopes(raw) : spoken
        Automation.mark("director: forward reply=\(reply)")
        return reply.isEmpty ? nil : reply
    }

    /// One agent turn: the on-device director when enabled, else the remote
    /// agent. A director turn that fails falls back to the remote path.
    private func reply(
        peerId: String,
        text: String,
        logPrefix: String,
        spokenTurnId: String? = nil
    ) async -> (display: String, spoken: String)? {
        if let localAgent {
            guard let spoken = await OnDeviceAgentRunner.shared.reply(
                agent: localAgent, text: text
            ) else {
                Automation.mark("\(logPrefix): FAIL on-device reply")
                return nil
            }
            if let spokenTurnId {
                ChatStore.shared.recordSpokenTurn(
                    peerId: peerId, callId: callId, turnId: spokenTurnId,
                    role: "agent", text: spoken
                )
            }
            return (display: spoken, spoken: spoken)
        }
        if DirectorRuntime.shared.enabled, let spoken = await DirectorRuntime.shared.turn(text) {
            if let spokenTurnId {
                ChatStore.shared.recordSpokenTurn(
                    peerId: peerId, callId: callId, turnId: spokenTurnId,
                    role: "agent", text: spoken
                )
            }
            return (display: spoken, spoken: spoken)
        }
        return await sendAndAwait(
            peerId: peerId, text: text, logPrefix: logPrefix, spokenTurnId: spokenTurnId
        )
    }

    private func sendAndAwait(
        peerId: String,
        text: String,
        logPrefix: String,
        spokenTurnId: String? = nil
    ) async -> (display: String, spoken: String)? {
        guard let message = await sendAndMatchReply(
            peerId: peerId, text: text, turnId: spokenTurnId, logPrefix: logPrefix),
              case .text(let raw) = message.kind else {
            Automation.mark("\(logPrefix): FAIL no reply")
            return nil
        }
        let display = Self.stripEnvelopes(raw)
        // The model sends the spoken form via `speak`; when it does not, the
        // reply text is what gets spoken (backward compatible).
        let spoken = Self.spokenText(from: raw)
        // Relabel the agent's reply as a spoken bubble (voice-call turns are
        // distinguished from typed ones by the "spoken" annotation).
        if let spokenTurnId {
            ChatStore.shared.recordSpokenTurn(
                peerId: peerId, callId: callId, turnId: spokenTurnId,
                role: "agent", text: spoken, replacing: message.id
            )
        }
        return (display, spoken)
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        stopRequested = true
        DirectorRuntime.shared.endCall()
        segmenter.stop()
        turnShadow?.stop()
        turnShadow = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        tts.playback = nil
        asr?.stop()
        asr = nil
        deliver(nil)
        activePeerId = nil
        agentPeerId = nil
        localAgent = nil
        micMuted = false
        turnsDone = 0
        turnLimit = Int.max
        noSpeechTurns = 0
        silencePrompted = false
        setState(.idle)
        // Play the end cue, then release the session once it has played out.
        CallTonePlayer.shared.start(.ended)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.isActive else { return }
            CallTonePlayer.shared.stop()
            AudioIO.shared.stop()
        }
    }

    private func setState(_ next: State) {
        state = next
        onState?(next)
        turnShadow?.setMode({ if case .speaking = next { "speaking" } else { "listen" } }())
    }

    /// Builds the bar's live readout from the active engines' last latency.
    private func updateStats() {
        let asrLabel: String
        switch asr?.name {
        case "parakeet-redux": asrLabel = "Parakeet"
        case "system": asrLabel = "Apple"
        default: asrLabel = asr?.name ?? "speech"
        }
        var parts: [String] = []
        if let ms = asr?.lastLatencyMs {
            parts.append("\(asrLabel) \(ms) ms")
        } else if lastListenMs > 0 {
            parts.append("\(asrLabel) \(lastListenMs) ms")
        } else {
            parts.append(asrLabel)
        }
        let ttsLabel = tts.name == "kokoro" ? "Kokoro" : tts.name.capitalized
        if let ms = tts.lastLatencyMs {
            parts.append("\(ttsLabel) \(String(format: "%.1f", Double(ms) / 1000)) s")
        } else {
            parts.append(ttsLabel)
        }
        stats = parts.joined(separator: " · ")
        Automation.mark("voice-agent: stats=\(stats ?? "nil")")
    }

    /// Call-UI mute: close/open the mic gate. The next `listenOnce` respects it.
    var audioEnabled: Bool { !micMuted }

    func setAudioEnabled(_ enabled: Bool) {
        micMuted = !enabled
        guard let asr else { return }
        if enabled { asr.resume() } else { asr.pause() }
    }

    // MARK: - analyzer lifecycle

    /// One session for the whole voice mode: the analyzer records while TTS
    /// plays back on the same play-and-record session, so `speak()` must not
    /// reconfigure it mid-session.
    private func configureSession() {
        // The single audio owner configures the session (`.voiceChat`, VPIO) and
        // starts capture/playback; this class only re-asserts the caller's
        // speaker preference after route changes.
        AudioIO.shared.start(profile: .voiceAgent)
        // Shadow turn-taker: load the models off the main path; TurnShadow then
        // feeds itself from the capture observer.
        if turnShadow == nil {
            Task.detached { [weak self] in
                // Deferred past the call-start audio churn: compiling/loading
                // the models in the first second contends with the session
                // setup and aggravates the engine's config-change self-stop
                // (the tone-silence regression). The shadow is decision-log
                // only — a few seconds late costs nothing.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let shadow = await TurnShadow.start()
                shadow?.onDecision = { [weak self] kind in
                    // the shadow queue calls this; the session is MainActor
                    Task { @MainActor in self?.turnDecision(kind) }
                }
                self?.turnShadow = shadow
            }
        }
        // Track route changes: enabling voice processing (and other session
        // reconfigurations) can drop `.voiceChat` back to the receiver after
        // the initial override, so the guard re-asserts the caller's choice.
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
        preferSpeaker = true
        applySpeakerRoute()
        logRoute("voice: route")
    }

    /// Re-assert the loudspeaker (or the caller's earpiece choice) whenever the
    /// route is not what `preferSpeaker` says it should be.
    private func applySpeakerRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        if preferSpeaker, outputs.contains(.builtInReceiver) {
            try? session.overrideOutputAudioPort(.speaker)
        } else if !preferSpeaker, outputs.contains(.builtInSpeaker) {
            try? session.overrideOutputAudioPort(.none)
        }
    }

    private func handleRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        logRoute("voice: route changed reason=\(raw.map { String($0) } ?? "?")")
        applySpeakerRoute()
    }

    private func logRoute(_ prefix: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        Automation.mark(
            "\(prefix) outputs=\(outputs) category=\(session.category.rawValue) mode=\(session.mode.rawValue) preferSpeaker=\(preferSpeaker)"
        )
    }

    /// Bar speaker toggle for the client cascade.
    func setSpeakerphone(_ enabled: Bool) {
        preferSpeaker = enabled
        applySpeakerRoute()
        logRoute("voice: speaker")
    }

    private func startAnalyzer() async {
        // Parakeet is English-only and downloads/compiles on first use, so a
        // failure falls back to the built-in recognizer (system language)
        // rather than dropping the call.
        let backends: [AsrBackend] = asrBackend == .parakeet ? [.parakeet, .system] : [asrBackend]
        var lastError: Error?
        for backend in backends {
            guard let engine = SpeechEngines.makeAsr(backend) else { continue }
            asr = engine
            do {
                try await engine.start(
                    // AEC so the mic can stay live while TTS plays (barge-in).
                    enableVoiceProcessing: true,
                    onText: { [weak self] text, isFinal in
                        DispatchQueue.main.async { self?.segmenter.handle(text, isFinal: isFinal) }
                    },
                    onError: { [weak self] message in
                        Automation.mark("voice-agent: analyzer error \(message)")
                        DispatchQueue.main.async { self?.restartAnalyzer() }
                    }
                )
            } catch {
                lastError = error
                Automation.mark(
                    "voice-agent: analyzer start failed backend=\(backend.rawValue) \(error.localizedDescription)"
                )
                engine.stop()
                asr = nil
                continue
            }
            // A hang-up during the (slow) start must not leave the engine running.
            if stopRequested {
                engine.stop()
                asr = nil
            }
            return
        }
        asr = nil
        CallFeedback.post(
            "No voice call available: \(lastError?.localizedDescription ?? "no recognizer for this contact")"
        )
    }

    /// LiveSub's lesson: a failed recognizer stays dead until reset. Rebuild it.
    private func restartAnalyzer() {
        guard isActive else { return }
        asr?.stop()
        asr = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.isActive else { return }
            await self.startAnalyzer()
        }
    }

    // MARK: - prompt handoff

    private func deliver(_ text: String?) {
        guard let waiter = promptWaiter else { return }
        promptWaiter = nil
        waiter.resume(returning: text)
    }

    private func awaitPrompt() async -> String? {
        if stopRequested { return nil }
        return await withCheckedContinuation { continuation in
            if stopRequested { continuation.resume(returning: nil); return }
            promptWaiter = continuation
        }
    }

    // MARK: - speech

    /// One user turn. On iOS 26+ the analyzer is already running; the mic is
    /// resumed for the turn and paused again while the agent responds.
    private func listenOnce(timeout: TimeInterval = 20) async -> String? {
        if let asr {
            // Muting must not end the call: wait for unmute, then listen.
            if micMuted {
                segmenter.setEnabled(false)
                asr.pause()
                while micMuted && !stopRequested {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if stopRequested { return nil }
            }
            segmenter.setEnabled(true)
            segmenter.clear()
            asr.resume()
            let heard = await awaitPromptWithTimeout(timeout)
            segmenter.setEnabled(false)
            asr.pause()
            return heard
        }
        return await listenWithSFSpeech(timeout: timeout)
    }

    private func awaitPromptWithTimeout(_ timeout: TimeInterval) async -> String? {
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.deliver(nil)
        }
        let heard = await awaitPrompt()
        deadline.cancel()
        return heard
    }

    /// Older iOS: one SFSpeech listening phase per turn.
    private func listenWithSFSpeech(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            var latest = ""
            var lastChange = Date()
            let started = Date()
            var resumed = false
            var timer: Timer?
            let finish: (String?) -> Void = { text in
                guard !resumed else { return }
                resumed = true
                timer?.invalidate()
                self.voice.stopListening()
                continuation.resume(returning: text)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                if self.stopRequested {
                    finish(latest.isEmpty ? nil : latest)
                } else if !latest.isEmpty, Date().timeIntervalSince(lastChange) > 1.2 {
                    finish(latest)
                } else if Date().timeIntervalSince(started) > timeout {
                    finish(latest.isEmpty ? nil : latest)
                }
            }
            self.voice.startListening(
                onPartial: { text in
                    latest = text
                    lastChange = Date()
                    self.setState(.listening(text))
                }
            ) { result in
                timer?.invalidate()
                switch result {
                case .success(let text): finish(text)
                case .failure: finish(latest.isEmpty ? nil : latest)
                }
            }
        }
    }

    /// Send one turn and match its reply. The snapshot of known ids is taken
    /// after ChatStore hydration — a late restored-history message must never
    /// be taken for the reply — and the request names its turn so the reply
    /// can be matched exactly (see `waitForReply`).
    private func sendAndMatchReply(
        peerId: String, text: String, turnId: String?, logPrefix: String
    ) async -> ChatMessage? {
        await ChatStore.shared.whenHydrated()
        let before = Set(ChatStore.shared.messages(for: peerId).map(\.id))
        do {
            try await client.sendText(
                to: peerId, text,
                context: turnId.map { "\(callContext)\nTurn: \($0)" } ?? callContext)
        } catch {
            Automation.mark("\(logPrefix): FAIL send \(error.localizedDescription)")
            return nil
        }
        return await waitForReply(peerId: peerId, excluding: before, expecting: turnId)
    }

    /// The reply to one turn: the new agent message whose speak envelope
    /// carries this turn's correlation id (`docs/voice-agent-loop-contract.md`:
    /// the reply echoes the request's `Turn: <id>` context line as
    /// `speak.correlation_id`). A message correlated to a *different* turn
    /// (e.g. a late greeting reply) is never spoken as this turn's answer.
    /// Agents that set no correlation id fall back to the first new message —
    /// the historical behavior.
    private func waitForReply(
        peerId: String, excluding: Set<String>, expecting correlationId: String?
    ) async -> ChatMessage? {
        for _ in 0..<60 {
            if stopRequested { return nil }
            var legacy: ChatMessage?
            for message in ChatStore.shared.messages(for: peerId).reversed()
            where !message.outgoing && !excluding.contains(message.id) {
                guard case .text(let raw) = message.kind else { continue }
                if let expected = correlationId, let id = SpeakEnvelope.correlationIds(in: raw).first {
                    if id == expected { return message }
                    continue
                }
                if legacy == nil { legacy = message }
            }
            if let legacy { return legacy }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func speak(_ text: String) async -> String? {
        Automation.mark("voice-agent: speak begin chars=\(text.count)")
        // A reply supersedes voice feedback still playing: ENDPOINT can land
        // inside a "mm-hm". Stop it and await the drained task so two speaks
        // never overlap (each engine is single-utterance).
        if feedbackTask != nil {
            tts.stop()
            await feedbackTask?.value
            feedbackTask = nil
        }
        lastSpoken = text
        // Arm barge-in: keep the recognizer live while TTS plays. AEC keeps the
        // agent's own voice out, so a cancellable non-echo utterance is the
        // caller interrupting.
        let armed = !micMuted && asr != nil
        if armed {
            bargeInArmed = true
            bargeInHeard = nil
            segmenter.clear()
            segmenter.setEnabled(true)
            asr?.resume()
        }
        await tts.speak(text)
        Automation.mark("voice-agent: speak done")
        var interrupted: String?
        if armed {
            bargeInArmed = false
            interrupted = bargeInHeard
            bargeInHeard = nil
            segmenter.setEnabled(false)
            asr?.pause()
        }
        // Hold the tap gate closed so the speaker's physical flush and VPIO's
        // residual tail decay before the next turn re-arms the mic; 800 ms
        // covers output latency + reverb tail, not just the room (
        // docs/voice-side-channel.md). Skip when stopping or already
        // interrupted (the barge-in text is the next turn).
        if !stopRequested, interrupted == nil {
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return interrupted
    }

    /// The turn model's decisions (the tyger option): ENDPOINT commits the
    /// turn now, BARGE stops playback. Fail-open: the Segmenter's classic
    /// signals stay live; nothing here can block a call.
    private func turnDecision(_ kind: String) {
        // The shadow queue calls this; the segmenter, TTS and barge state are
        // main-thread. Marshal the whole handler.
        DispatchQueue.main.async { [weak self] in
            guard let self, TurnTakerSetting.usesModel(for: self.activePeerId, modelAvailable: true) else { return }
            switch kind {
            case "ENDPOINT":
                Automation.mark("turn-taker: tyger endpoint -> commit")
                self.segmenter.forceCommit()
            case "BARGE":
                guard self.bargeInArmed else { return }
                Automation.mark("turn-taker: tyger barge -> stop playback")
                self.tts.stop()
            case "BACKCHANNEL":
                self.utterFeedback()
            default:
                break
            }
        }
    }

    /// Tyger BACKCHANNEL: a short "mm-hm" over the caller's turn. Voice
    /// feedback only — never in history (`lastSpoken` untouched: no chat
    /// bubble, no echo bookkeeping) and never in the second ear
    /// (FeedbackEar). The rules keep their own refractory; the gap here stops
    /// playback-level stacking.
    private func utterFeedback() {
        guard !stopRequested, feedbackTask == nil, case .listening(let heard) = state, !bargeInArmed else { return }
        if let at = lastFeedbackAt, Date().timeIntervalSince(at) < 1.2 { return }
        lastFeedbackAt = Date()
        Automation.mark("turn-taker: tyger backchannel -> feedback")
        feedbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Contextual ack off the ASR partial (the tyger filler recipe on
            // AFM, fail-open to nil). "Mm-hmm." renders as a clean hum in
            // Phonon; "Mm-hm." phonemizes to nonsense (heard as "lim").
            // Round-trip any change (TTS → ASR).
            let text = await BackchannelFiller.ack(partial: heard) ?? "Mm-hmm."
            guard case .listening = self.state, !self.stopRequested else {
                self.feedbackTask = nil
                return
            }
            self.lastFeedback = text
            await FeedbackEar.suppress { await self.tts.speak(text) }
            self.feedbackTask = nil
        }
    }

    /// True while the mic may still be re-hearing the agent's own feedback cue
    /// (cue playback + the segmenter's 1.2 s gap-commit lag). The window is
    /// short on purpose: a later real "mm-hm" is a turn again.
    private func isFeedbackEcho(_ text: String) -> Bool {
        guard let lastFeedback, let at = lastFeedbackAt,
              Date().timeIntervalSince(at) < 3
        else { return false }
        return voice.isEcho(spoken: lastFeedback, heard: text)
    }

    /// A committed utterance: normally it ends the listen turn; while the agent
    /// speaks it may cancel playback (barge-in).
    private func handleCommit(_ text: String) {
        guard bargeInArmed else {
            // The mic can re-hear the agent's own feedback cue; it must not
            // become a caller turn.
            if isFeedbackEcho(text) {
                Automation.mark("voice-agent: dropped feedback echo text=\(text)")
                return
            }
            deliver(text)
            return
        }
        guard !micMuted,
              voice.isCancellable(text),
              !voice.isEcho(spoken: lastSpoken ?? "", heard: text),
              !isFeedbackEcho(text)
        else {
            Automation.mark("voice-agent: barge-in ignored text=\(text)")
            return
        }
        Automation.mark("voice-agent: barge-in engaged text=\(text)")
        bargeInHeard = text
        tts.stop()
    }

    /// Drop `IDFON-*/1` envelope blocks so only the spoken text is read aloud.
    private static func launchString(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: flag), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }

    static func stripEnvelopes(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("IDFON-") && line.hasSuffix("/1") { break }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The spoken form of a raw reply: `IDFON-SPEAK/1` text when present, else
    /// the reply with envelopes stripped.
    private static func spokenText(from raw: String) -> String {
        let texts = SpeakEnvelope.texts(in: raw)
        return texts.isEmpty ? stripEnvelopes(raw) : texts.joined(separator: " ")
    }
}
