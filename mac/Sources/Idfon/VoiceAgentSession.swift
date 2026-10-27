import AVFAudio
import Foundation
import Speech

/// A1 client-side voice agent loop (macOS): on-device STT -> text turn to the
/// agent peer -> await the reply -> on-device TTS. Mirror of the iOS
/// `VoiceAgentSession`; the macOS app owns all audio.
///
/// One long-lived analyzer stays prepared for the whole session; the mic tap
/// stays live while the agent speaks so the caller can barge in (echo + gated
/// peak filters cancel the agent's own TTS). `VoicePromptSegmenter` picks
/// utterance boundaries: a final result commits immediately, a 1.2 s no-change
/// gap is the fallback. macOS 26+ uses the SpeechAnalyzer; older macOS falls
/// back to a per-turn SFSpeechRecognizer.
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
    /// Reply-voice and recognizer backends; resolved per contact at `start`.
    private var tts: TtsEngine = SpeechEngines.tts
    private var ttsBackend = SpeechEngines.ttsBackend
    private var asrBackend = SpeechEngines.asrBackend
    private let segmenter = VoicePromptSegmenter()
    private var asr: (any AsrEngine)?
    /// Shadow turn-taker (decision-log diff only; see TurnShadow). Audio-thread
    /// writes + main-thread create/teardown, like `stopRequested`.
    nonisolated(unsafe) private var turnShadow: TurnShadow?

    private(set) var isActive = false
    /// Peer this voice call is with, so the shared call UI can title it.
    private(set) var activePeerId: String?
    /// The on-device agent this call is with, if any: turns run locally on AFM
    /// with no peer and no network (`docs/voice-agent-modes.md`).
    private var localAgent: OnDeviceAgent?
    /// The resolved peer id of this call: the proxy's `voice_forward` forwards
    /// to it (`Director.forwardCallback`).
    private var agentPeerId: String?
    /// Latest state, readable by the call UI (the `onState` callback is single-
    /// owner, so the LiveActivityController owns it).
    private(set) var state: State = .idle
    /// One-line live readout for the call bar, e.g. "Apple 900 ms".
    private(set) var stats: String?
    /// Capture->final time of the last turn.
    private var lastListenMs = 0
    /// Mic gate, driven by the call UI's mute button.
    private var micMuted = false
    var onState: ((State) -> Void)?

    // Timer's @Sendable closure can't see MainActor isolation; this flag is only
    // ever read/written on the main thread (stop() is MainActor, timers run on main).
    nonisolated(unsafe) private var stopRequested = false
    private var turnLimit = Int.max
    private var turnsDone = 0
    /// Consecutive silent turns; a call is only dropped after several.
    private var noSpeechTurns = 0
    /// True once the "are you still there?" check-in has been spoken this call.
    private var silencePrompted = false
    /// Identifier for this call, scoping the spoken-turn transcripts.
    private var callId = UUID().uuidString
    private var client = DaemonClient()
    private var promptWaiter: CheckedContinuation<String?, Never>?
    /// Last text spoken by TTS, so the agent's own tail can be dropped instead
    /// of re-sent as a user turn (self-bleed).
    private var lastSpoken: String?
    /// The agent's recent spoken turns (memory-only): the caller's turn can
    /// pick up several of them while barge-in keeps the mic live.
    private var spokenRecent: [String] = []
    /// The prefix of a barge-cut reply that actually played (their
    /// `add_barged` trim): the next turn must be told "you only said this
    /// much" or the agent continues from words the caller never heard.
    private var cutReply: String?
    /// Audio seconds that played in the last `speak` (summed across chunks).
    private var lastPlayedSeconds: TimeInterval = 0
    /// Voice feedback ("mm-hm") that played and when: it never enters history
    /// (`lastSpoken` stays the agent's reply) and is only echo-checked near its
    /// playback window, so a later real "mm-hm" can still be a turn.
    private var lastFeedback: String?
    private var lastFeedbackAt: Date?
    /// In-flight feedback utterance; drained before a reply speaks.
    private var feedbackTask: Task<Void, Never>?
    /// The filler cover over reply latency (tool lead-ins / still-looking
    /// lines); cancelled the moment the reply arrives.
    private var fillerTask: Task<Void, Never>?
    /// True while the filler is inside `tts.speak`, so cancellation cuts the
    /// line and drains it instead of racing the reply's speak.
    private var fillerSpeaking = false
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
        guard !isActive else { return }
        isActive = true
        localAgent = agent
        stopRequested = false
        callId = UUID().uuidString
        turnLimit = turns
        turnsDone = 0
        activePeerId = peerRef
        micMuted = false
        segmenter.onPartial = { [weak self] text in
            guard let self, !self.bargeInArmed else { return }
            self.setState(.listening(text))
        }
        segmenter.onCommit = { [weak self] text in self?.handleCommit(text) }
        SpeechEngines.prewarm()
        segmenter.start()
        Task { @MainActor in
            let peer: Peer
            if let localAgent {
                peer = localAgent.peer
            } else {
                let peers = (try? await client.peers()) ?? []
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
            // Reset the model history before a new call: the session log is
            // the medium, never the model's context (docs/session-context.md).
            // Sent early; the engine prep and greeting that follow give the
            // clear time to land. An on-device agent has no peer to tell.
            if localAgent == nil {
                try? await client.sendText(to: peer.id, "IDFON-SESSION/1\naction=rotate")
            }
            // Fetch the greeting concurrently with the engine prep below: it
            // only needs the transport (the peer's history was just rotated),
            // while the analyzer start and the hydration sleep don't need it.
            // Serial, the caller hears "answered" plus analyzer start plus a
            // 1.5 s hydration sleep plus the agent's full round-trip — the
            // greeting is an agent turn and the round-trip is its floor.
            var greeting: (display: String, spoken: String)?
            let greetTask: Task<(display: String, spoken: String)?, Never>? =
                (localAgent == nil && !stopRequested)
                ? Task { [weak self] in
                    guard let self else { return nil }
                    return await self.sendAndAwait(
                        peerId: peer.id,
                        text: "The caller just connected on a voice call. Greet them briefly and invite them to speak.",
                        logPrefix: "voice-agent-greet",
                        spokenTurnId: "\(callId)-greet"
                    )
                }
                : nil
            // Per-contact on-device engines (else the app defaults). Resolved
            // here, once the peer id is known, before the recognizer is built.
            ttsBackend = ContactOnDeviceEngines.tts(for: peer.id).flatMap(TtsBackend.init(rawValue:)) ?? SpeechEngines.ttsBackend
            tts = SpeechEngines.makeTts(ttsBackend)
            asrBackend = ContactOnDeviceEngines.asr(for: peer.id).flatMap(AsrBackend.init(rawValue:)) ?? SpeechEngines.asrBackend
            // Proxy mode: load and warm the AFM director behind the ringback.
            // No-op unless this contact is set to proxy (or `-directorcall`
            // forces it); an app-local agent uses `OnDeviceAgentRunner` instead.
            if localAgent == nil {
                await DirectorRuntime.shared.startCall(
                    proxy: ContactVoiceTurnModes.mode(for: peer.id) == .proxy)
            }
            // Wait for the recognizer before the turn loop (first-run model).
            await startAnalyzer()
            setState(.listening(""))
            // Greet like a live call, fetched before the cue so "answered" is
            // followed immediately by speech instead of dead air.
            if let greetTask {
                greeting = await greetTask.value
            } else if !stopRequested {
                let greetTurn =
                    "The caller just connected on a voice call. Greet them briefly and invite them to speak."
                // An app-local agent greets locally. A proxy or passive call
                // greets through the agent, so the caller never hears the
                // director's persona (`docs/voice-agent-modes.md`).
                if localAgent != nil {
                    greeting = await reply(
                        peerId: peer.id, text: greetTurn,
                        logPrefix: "voice-agent-greet",
                        spokenTurnId: "\(callId)-greet"
                    )
                }
            }
            CallTonePlayer.shared.start(.answered)
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
        stopRequested = true
        // Cancel in-flight speech now; otherwise hang-up waits out the whole
        // utterance while the loop is parked in `speak()`.
        fillerTask?.cancel()
        fillerTask = nil
        tts.stop()
        deliver(nil)
    }

    private func setState(_ next: State) {
        state = next
        turnShadow?.setMode({ if case .speaking = next { "speaking" } else { "listen" } }())
        onState?(next)
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

    func run(peerRef: String, turns: Int) {
        start(peerRef: peerRef, turns: turns)
    }

    func runText(peerRef: String, text: String) {
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
                Automation.mark("voice-agent: asr listen_ms=\(lastListenMs)")
                var own = text
                if let spoken = lastSpoken, !spoken.isEmpty {
                    if voice.isEcho(spoken: spoken, heard: text) {
                        Automation.mark("voice-agent: dropped echo heard=\(text)")
                        continue
                    }
                    // Mixed transcripts (the agent's replies leaking into the
                    // caller's turn — the no-AEC stereo route with barge-in
                    // hearing): keep the caller's own words only.
                    let stripped = voice.stripEcho(
                        spoken: spokenRecent.joined(separator: " \(spoken) "), heard: text)
                    if stripped != text {
                        Automation.mark("voice-agent: echo stripped=\(stripped)")
                        own = stripped
                    }
                }
                guard !own.isEmpty else { continue }
                // Optional on-device LM cleanup (fail-open to the raw transcript).
                let corrected = await SpeechCorrection.correct(own)
                if corrected != own {
                    Automation.mark("voice-agent: corrected=\(corrected)")
                }
                heard = corrected
                break
            }
        }
        guard let heard, !heard.isEmpty else {
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
        // Show the caller's spoken turn in the chat, not just the agent's reply.
        ChatStore.shared.recordSpokenTurn(
            peerId: peerId, callId: callId,
            turnId: "\(callId)-\(turnsDone)-user", role: "caller", text: heard
        )
        setState(.thinking)
        let replyStart = Date()
        startFillerCover(transcript: heard)
        guard let result = await reply(
            peerId: peerId, text: heard, logPrefix: "voice-agent",
            spokenTurnId: "\(callId)-\(turnsDone)-agent"
        )
        else {
            await cancelFiller()
            // A missing reply must not kill the call; try the next turn.
            Automation.mark("voice-agent: no reply, continuing")
            return true
        }
        await cancelFiller()
        let replyMs = Int(Date().timeIntervalSince(replyStart) * 1000)
        Automation.mark("voice-agent: reply=\(result.display)")
        var speakMs = 0
        if !result.spoken.isEmpty {
            setState(.speaking(result.spoken))
            let speakStart = Date()
            pendingHeard = await speak(result.spoken)
            if pendingHeard != nil {
                let played = lastPlayedSeconds
                cutReply = played > 0
                    ? Self.playedPrefix(of: result.spoken, seconds: played)
                    : result.spoken
                Automation.mark("voice-agent: reply cut said=" + (cutReply ?? ""))
            }
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
    /// Forward one turn to the called agent and return its reply text (the
    /// director's `voice_forward`). No chat bookkeeping; the director speaks the
    /// reply. Called from the director's background thread via a callback.
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

    private var callContext: String {
        "Client cascade (on-device speech). Recognition: \(asrBackend.title); Generation: \(ttsBackend.title). The holder only produces text."
    }

    /// One agent turn. An on-device agent answers locally on AFM; every other
    /// contact is a remote (passive) turn.
    private func reply(
        peerId: String,
        text: String,
        logPrefix: String,
        spokenTurnId: String? = nil
    ) async -> (display: String, spoken: String)? {
        guard let localAgent else {
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
        guard let spoken = await OnDeviceAgentRunner.shared.reply(agent: localAgent, text: text) else {
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
        segmenter.stop()
        turnShadow?.stop()
        turnShadow = nil
        asr?.setSamplesHandler(nil)
        asr?.stop()
        asr = nil
        deliver(nil)
        activePeerId = nil
        agentPeerId = nil
        DirectorRuntime.shared.endCall()
        localAgent = nil
        micMuted = false
        turnsDone = 0
        turnLimit = Int.max
        noSpeechTurns = 0
        silencePrompted = false
        setState(.idle)
        // Play the end cue, then release the tone engine once it has played out.
        CallTonePlayer.shared.start(.ended)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.isActive else { return }
            CallTonePlayer.shared.stop()
        }
    }

    // MARK: - analyzer lifecycle

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
                    enableVoiceProcessing: false,
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
            // Shadow turn-taker: same audio, decision-log diff only. Samples
            // drop until the model has loaded; the load must not block the UI.
            engine.setSamplesHandler { [weak self] samples, rate in
                self?.turnShadow?.feed(samples, rate: rate)
            }
            Task { @MainActor [weak self] in
                guard let self, self.turnShadow == nil else { return }
                let shadow = await Task.detached { TurnShadow.start() }.value
                shadow?.onDecision = { [weak self] kind in self?.turnDecision(kind) }
                self.turnShadow = shadow
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

    /// One user turn. The analyzer is already running; the mic is resumed for
    /// the turn and paused again while the agent responds.
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

    /// Older macOS: one SFSpeech listening phase per turn.
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
                enableVoiceProcessing: false,
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

    /// The words that actually played before a barge cut — their
    /// `played_s * 25` characters-per-second estimate, snapped to a word.
    nonisolated static func playedPrefix(of text: String, seconds: TimeInterval) -> String {
        let cut = text.index(text.startIndex, offsetBy: min(text.count, Int(seconds * 25)))
        let prefix = String(text[..<cut])
        guard let lastSpace = prefix.lastIndex(of: " ") else { return prefix }
        return String(prefix[..<lastSpace])
    }

    /// Send one turn and match its reply. The snapshot of known ids is taken
    /// after ChatStore hydration — a late restored-history message must never
    /// be taken for the reply — and the request names its turn so the reply
    /// can be matched exactly (see `waitForReply`).
    private func sendAndMatchReply(
        peerId: String, text: String, turnId: String?, logPrefix: String
    ) async -> ChatMessage? {
        await ChatStore.shared.whenHydrated()
        var context = callContext
        if let cut = cutReply {
            // "You only said this much" (the barge-history trim, slice 3).
            context += "\nYour previous reply was interrupted after: \"\(cut)\" — continue from there without repeating it."
            cutReply = nil
        }
        if let turnId { context += "\nTurn: \(turnId)" }
        let before = Set(ChatStore.shared.messages(for: peerId).map(\.id))
        do {
            try await client.sendText(to: peerId, text, context: context)
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
        // A reply supersedes voice feedback still playing: ENDPOINT can land
        // inside a "mm-hm". Stop it and await the drained task so two speaks
        // never overlap (each engine is single-utterance).
        if feedbackTask != nil {
            tts.stop()
            await feedbackTask?.value
            feedbackTask = nil
        }
        lastSpoken = text
        spokenRecent.append(text)
        if spokenRecent.count > 3 { spokenRecent.removeFirst(spokenRecent.count - 3) }
        // Arm barge-in: keep the recognizer live while TTS plays. The echo and
        // gated-peak filters keep the agent's own voice out, so a cancellable
        // non-echo utterance is the caller interrupting.
        let armed = !micMuted && asr != nil
        if armed {
            bargeInArmed = true
            bargeInHeard = nil
            segmenter.clear()
            asr?.utteranceCommitted()
            segmenter.setEnabled(true)
            asr?.resume()
        }
        // Chunked speak (their mouth/chunker.py pattern): sentences go to
        // the mouth as they close — the seam reply deltas will feed per-chunk.
        // Played time accumulates across chunks for the barge trim.
        var played: TimeInterval = 0
        for chunk in SpeechChunker.chunks(text) {
            if stopRequested || bargeInHeard != nil { break }
            await tts.speak(SpeechChunker.sayClean(chunk))
            played += tts.playedSeconds
        }
        lastPlayedSeconds = played
        var interrupted: String?
        if armed {
            bargeInArmed = false
            interrupted = bargeInHeard
            bargeInHeard = nil
            segmenter.setEnabled(false)
            asr?.pause()
        }
        // Hold the tap gate closed briefly so the speaker/acoustic tail decays
        // before the next turn re-arms the mic; skip when stopping or already
        // interrupted (the barge-in text is the next turn).
        if !stopRequested, interrupted == nil {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return interrupted
    }

    /// A committed utterance: normally it ends the listen turn; while the agent
    /// speaks it may cancel playback (barge-in).
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
            // AFM, fail-open to a rotating safe word). Hum spellings never
            // reach the mouth: Phonon sounds letter strings out as words
            // ("mm-hm" is heard as "lim", "mm" as "meem").
            let text = await BackchannelFiller.ack(partial: heard) ?? BackchannelFiller.fallbackCue()
            guard case .listening = self.state, !self.stopRequested else {
                self.feedbackTask = nil
                return
            }
            self.lastFeedback = text
            await FeedbackEar.suppress { await self.tts.speak(text) }
            self.feedbackTask = nil
        }
    }

    /// The filler economy (tyger-s2s's tool lead-ins + "still looking" lines,
    /// their `mouth/turns.py` `cover()`): while the reply is out, a fast
    /// phatic line on the clock covers the dead air a tool call or a slow
    /// model leaves. Voice feedback only — never in history (`lastSpoken`
    /// stays the agent's reply) and never in the second ear (FeedbackEar);
    /// the reply supersedes it (`cancelFiller`).
    private func startFillerCover(transcript: String) {
        fillerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var said: [String] = []
            while let wait = TurnFiller.nextWait(saidCount: said.count) {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, !self.stopRequested, case .thinking = self.state else { return }
                let still = !said.isEmpty
                // The lead-in fallback is the ear-gated autoresearch winner
                // (2026-10-26): lowercase "so." renders with a drawn-out soft
                // onset — the one hesitation lead that measures and sounds
                // like a human's (docs/voice-calibration.md).
                let text = await TurnFiller.line(transcript: transcript, said: said, still: still)
                    ?? (still ? "Still on it." : "so. One moment.")
                guard !Task.isCancelled, !self.stopRequested, case .thinking = self.state else { return }
                said.append(text)
                Automation.mark("voice-agent: filler \(still ? "still" : "lead-in") said=\(text)")
                // Echo bookkeeping before playback, like the backchannel cue:
                // a re-heard filler must not become a caller turn.
                self.lastFeedback = text
                self.lastFeedbackAt = Date()
                self.fillerSpeaking = true
                await FeedbackEar.suppress { await self.tts.speak(text) }
                self.fillerSpeaking = false
            }
        }
    }

    /// The reply is here: cancel the filler cover, cutting a line still
    /// playing so the reply owns the mouth.
    private func cancelFiller() async {
        guard let task = fillerTask else { return }
        fillerTask = nil
        task.cancel()
        // Still generating or sleeping: its guards stop it before it speaks.
        guard fillerSpeaking else { return }
        tts.stop()
        await task.value
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

    private func handleCommit(_ text: String) {
        // The utterance is consumed here (spoken, or dropped as an echo): a
        // streaming recognizer's running transcript resets with it so its
        // partials stay per-utterance.
        asr?.utteranceCommitted()
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
              asr?.bargeInEngages ?? true,
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
