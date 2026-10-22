import AppKit
import AVFoundation
import CoreAudio
import CIdfon

/// A consumer of the shared mic stream — the single-input-owner consolidation:
/// STT/analysis components subscribe to the one VPIO tap instead of each
/// starting an `AVAudioEngine` (separate input graphs collide on device
/// switches and only the shared tap is echo-cancelled).
protocol AudioCaptureObserver: AnyObject {
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

/// Messages-style dotted waveform. Port of ios/Idfon/LiveWaveformView.swift
/// (UIKit UIView.draw -> AppKit NSView.draw). Low amplitudes render as small
/// dots on the center line; louder ones grow into vertical bars around it.
/// Two modes: live (scrolling, fed per-sample by a meter) and static (fixed
/// samples, e.g. a recorded file).
final class WaveformView: NSView {
    enum Mode {
        case live
        case staticSamples([Float])
    }

    var style: Style = .recording {
        didSet { needsDisplay = true }
    }
    var barCount = 64

    enum Style {
        case recording // red (Messages recording state)
        case playback  // gray (review/playback state)
    }

    private var mode: Mode = .live
    private var liveSamples: [Float]
    private var progress: Double = 0 // static mode: played fraction 0...1
    private let lock = NSLock()
    private var needsRedraw = false

    override init(frame: CGRect) {
        liveSamples = .init(repeating: 0, count: barCount)
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        liveSamples = .init(repeating: 0, count: barCount)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func startLive() {
        mode = .live
        liveSamples = .init(repeating: 0, count: barCount)
        needsDisplay = true
    }

    /// Amplitude in 0...1, safe from any thread; redraws coalesced per run-loop turn.
    func add(amplitude: Float) {
        lock.lock()
        liveSamples.removeFirst()
        liveSamples.append(min(max(amplitude, 0), 1))
        lock.unlock()
        scheduleRedraw()
    }

    /// Static waveform (a recorded file); progress is the played fraction.
    func setStatic(samples: [Float], progress: Double) {
        mode = .staticSamples(samples)
        self.progress = progress
        scheduleRedraw()
    }

    func setProgress(_ value: Double) {
        progress = value
        scheduleRedraw()
    }

    private func scheduleRedraw() {
        DispatchQueue.main.async {
            if self.needsRedraw { return }
            self.needsRedraw = true
            DispatchQueue.main.async {
                self.needsRedraw = false
                self.needsDisplay = true
            }
        }
    }

    /// Downsamples a wav file into normalized amplitudes for a static waveform
    /// (port of the iOS VoiceMemo.amplitudes helper).
    /// nonisolated: called from detached decode tasks.
    nonisolated static func amplitudes(url: URL, count: Int = 64) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return .init(repeating: 0, count: count) }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return .init(repeating: 0, count: count)
        }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return .init(repeating: 0, count: count) }

        var result = [Float](repeating: 0, count: count)
        let chunk = Int(buffer.frameLength) / max(count, 1)
        guard chunk > 0 else { return result }
        var peak: Float = 0.001
        for i in 0..<count {
            var maxSample: Float = 0
            for j in 0..<chunk {
                maxSample = max(maxSample, abs(data[i * chunk + j]))
            }
            result[i] = maxSample
            peak = max(peak, maxSample)
        }
        return result.map { $0 / peak }
    }

    override func draw(_ dirtyRect: NSRect) {
        lock.lock()
        let snapshot: [Float]
        switch mode {
        case .live: snapshot = liveSamples
        case .staticSamples(let samples): snapshot = samples
        }
        lock.unlock()

        let color = style == .recording ? NSColor.systemRed : NSColor.systemGray
        let playedColor = style == .recording ? color : NSColor.darkGray

        let count = CGFloat(max(snapshot.count, 1))
        let slot = dirtyRect.width / count
        let dotDiameter = min(slot * 0.55, 3)
        let midY = dirtyRect.midY

        for (index, amplitude) in snapshot.enumerated() {
            let x = CGFloat(index) * slot + slot / 2
            let fraction = Double(index) / Double(max(snapshot.count, 1))
            let drawColor = mode.isStatic && fraction <= progress ? playedColor : color
            drawColor.setFill()
            if amplitude < 0.08 {
                // idle dot on the center line
                let dot = NSRect(x: x - dotDiameter / 2, y: midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
                NSBezierPath(ovalIn: dot).fill()
            } else {
                // bar growing symmetrically around the center line
                let barWidth = max(dotDiameter, 2)
                let height = max(CGFloat(amplitude) * dirtyRect.height * 0.9, dotDiameter)
                let bar = NSRect(x: x - barWidth / 2, y: midY - height / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
        }
    }
}

private extension WaveformView.Mode {
    var isStatic: Bool {
        if case .staticSamples = self { return true }
        return false
    }
}

/// Mic amplitude meter: taps the engine input and feeds normalized RMS to a
/// waveform via a closure. Port of the iOS AudioMeter minus AVAudioSession
/// (which does not exist on macOS).
///
/// This engine is also the playback bus for remote call audio
/// (`AudioPlaybackSink` -> `playStream`): with voice processing on the input
/// node it is the VoiceProcessingIO echo reference (docs/audio-media.md) —
/// remote audio on any other graph cannot be echo-cancelled (the iOS AEC fix,
/// c3871b0, ported).
///
/// With `pushToEncoder` set, the same tap also feeds the live publisher's
/// generic audio ingest (`media_audio_push_samples`) at the selected mono f32
/// rate. The live-call meter is the sole mic capture in the dylib's "push"
/// mode, and these are the samples the peer hears (issue #7). Memo meters leave
/// it off.
final class AudioMeter {
    static let shared = AudioMeter()
    /// Capture observers (the single-input-owner consolidation): consumers of
    /// the mic subscribe here instead of starting their own AVAudioEngine —
    /// separate input graphs collide on device switches and only the shared
    /// tap is the VPIO/AEC-processed stream (docs/audio-media.md).
    private static let captureObservers = NSHashTable<AnyObject>.weakObjects()
    private static var headlessRunning = false

    static func addCaptureObserver(_ observer: AudioCaptureObserver) {
        DispatchQueue.main.async {
            captureObservers.add(observer as AnyObject)
            if activeInputMeter == nil && !headlessRunning {
                headlessRunning = true
                shared.start()
            }
        }
    }

    static func removeCaptureObserver(_ observer: AudioCaptureObserver) {
        DispatchQueue.main.async {
            captureObservers.remove(observer as AnyObject)
            if captureObservers.allObjects.isEmpty, headlessRunning {
                headlessRunning = false
                shared.stop()
            }
        }
    }

    /// Copy-under-lock-equivalent (main queue): an observer must not deadlock
    /// the audio thread.
    private static func fanOutCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let observers = captureObservers.allObjects
        for observer in observers {
            (observer as? AudioCaptureObserver)?.audioCapture(buffer, at: time)
        }
    }
    private static let logQueue = DispatchQueue(label: "idfon.audio-meter-log")
    private static func log(_ message: String) {
        idfonLog("\(message)")
        logQueue.async {
            let url = URL(fileURLWithPath: "/tmp/idfon-audio-\(ProcessInfo.processInfo.processIdentifier).log")
            let line = "\(Date()) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path), let file = try? FileHandle(forWritingTo: url) {
                    _ = try? file.seekToEnd()
                    try? file.write(contentsOf: data)
                    try? file.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
    // AVAudioEngine input taps are process-wide at the hardware input bus:
    // separate engines can still collide when macOS switches devices.
    private static let inputEngine = AVAudioEngine()
    private var engine: AVAudioEngine { Self.inputEngine }
    // One engine tap fans out to every attached waveform (inline call bar +
    // in-call recording bar share it; a second engine tap would race the mic).
    private struct WeakWave { weak var view: WaveformView? }
    private var views: [WeakWave] = []
    private(set) var running = false
    private var startInFlight = false
    private var tapInstalled = false
    /// Completions waiting on the in-flight start attempt; called on main
    /// once it settles (they read `running` for the outcome).
    private var pendingStarts: [() -> Void] = []
    private var startGeneration = 0
    private static weak var activeInputMeter: AudioMeter?
    private static var inputTapInstalled = false
    // Remote call audio renders on this engine's playback bus (see playStream).
    private static let playbackPlayer = AVAudioPlayerNode()
    private static var playbackAttached = false
    private static var voiceProcessingTried = false
    /// Playback state that must survive a stop/start cycle: the looping cue and
    /// one-shots mid-flight are dropped by engine.stop() (their completions
    /// fire, so callers resume while the audio silently vanishes — the iOS
    /// tone-silence class). `dropping` marks the stop window so completions
    /// route into `pendingRearm` instead of finishing.
    private static var activeLoop: AVAudioPCMBuffer?
    private static var inFlightOneShots: [UUID: (buffer: AVAudioPCMBuffer, completion: (() -> Void)?)] = [:]
    private static var pendingRearm: [UUID: (buffer: AVAudioPCMBuffer, completion: (() -> Void)?)] = [:]
    private static var dropping = false

    /// Opt in to feeding the call's encoder as well as the waveform. In the
    /// dylib's "push" mode the Rust side does not open the mic, so this tap is
    /// the call's sole capture; leaving it off (memo meters) only displays.
    var pushToEncoder = false

    /// The ingest rate defaults to 48 kHz and is selected per call/contact.
    private var targetSampleRate = 48_000
    /// 1 mono, 2 interleaved stereo; must match the publisher started with
    /// `media_live_start_with_profile` (mismatched pushes are dropped there).
    private var targetChannels = 1
    private var outputFormat: AVAudioFormat?
    /// Hardware format -> ingest format; keeps its resampler state across taps.
    private var converter: AVAudioConverter?

    private func pipelineFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSampleRate), channels: AVAudioChannelCount(targetChannels), interleaved: false)!
    }
    private var interruptionObserver: NSObjectProtocol?
    private var pushedBuffers = 0
    private var callbackBuffers = 0
    private var windowSamples = 0
    private var windowSumSquares = 0.0
    private var windowPeak = 0.0

    init(view: WaveformView? = nil) {
        if let view { views = [WeakWave(view: view)] }
    }

    /// Attach another waveform to the same meter.
    func add(view: WaveformView) {
        views.removeAll { $0.view == nil }
        if !views.contains(where: { $0.view === view }) { views.append(WeakWave(view: view)) }
    }

    /// Wired/USB/headphone output route (docs/stereo-calls.md): stereo call
    /// capture is allowed and the headset already attenuates the echo path, so
    /// the tap keeps its channels (voice processing skipped). Speaker routes
    /// keep the VPIO mono path; Bluetooth is excluded — its mic is mono HFP, so
    /// stereo buys nothing there.
    static func stereoCaptureAllowed() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            &size, &deviceID) == noErr, deviceID != 0 else { return false }
        // Headphones in the built-in jack: same output device, jack connected.
        var jack: UInt32 = 0
        var jackSize = UInt32(MemoryLayout<UInt32>.size)
        var jackAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyJackIsConnected,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(
            deviceID, &jackAddr, 0, nil, &jackSize, &jack) == noErr, jack == 1 {
            return true
        }
        // USB headsets/interfaces are their own output device.
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeUSB
    }

    /// The call audio mode picked on the live panel's media group (nil = the
    /// auto rule above). Drives the VPIO decision and the capture channel count
    /// (docs/stereo-calls.md).
    static var preferredMode: CallAudioMode?

    /// Stereo capture: the picked mode, or on auto the headset route.
    static func stereoCaptureForCall() -> Bool {
        if let preferredMode { return preferredMode == .earphone2D }
        return stereoCaptureAllowed()
    }

    /// The channel count the call's mic leg publishes.
    static func captureChannelsForCall() -> Int { stereoCaptureForCall() ? 2 : 1 }

    func configureForCall(sampleRate: Int, channels: Int? = nil) {
        guard sampleRate == 24_000 || sampleRate == 48_000 else { return }
        targetSampleRate = sampleRate
        if let channels { targetChannels = max(1, min(2, channels)) }
    }

    func start(sampleRate: Int? = nil, completion: (() -> Void)? = nil) {
        if let sampleRate { configureForCall(sampleRate: sampleRate) }
        Self.log("idfon audio meter start requested running=\(running) tap=\(tapInstalled) push=\(pushToEncoder) rate=\(targetSampleRate)")
        if let completion { pendingStarts.append(completion) }
        if running { settle(); return }
        guard !startInFlight else { return } // joins the in-flight attempt
        // The input tap is installed once per process and never removed:
        // installTap raises an uncapturable ObjC exception (aborting the app)
        // on re-install — every call start flips the audio route, which used
        // to restart the meter through a remove/install cycle and crashed
        // consistently. Engine start/stop gates delivery instead.
        startInFlight = true
        startGeneration += 1
        let generation = startGeneration
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Self.log("idfon audio meter permission granted=\(granted)")
            guard granted, let self, !self.running else {
                DispatchQueue.main.async { [weak self] in self?.settle() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                guard generation == self.startGeneration,
                      !self.running else {
                    // tapInstalled is no longer a staleness flag: the tap is
                    // process-sticky (see start()), so a second start simply
                    // reuses it via the inputTapInstalled branch below.
                    self.startInFlight = false
                    self.settle()
                    return
                }
                // The input bus accepts only one tap process-wide. This can be
                // hit during device changes when an old meter's permission
                // callback arrives after the UI has created the replacement.
                if let active = Self.activeInputMeter, active !== self { active.stop() }
                let input = self.engine.inputNode
                // VoIP-standard 10 ms capture IO: the tap otherwise delivers
                // 4800-frame (~100 ms) bursts on the default device. Best
                // effort — some devices reject the smaller block; the tap
                // callback log (frames=) shows what actually arrived.
                var deviceID = AudioDeviceID(0)
                var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                var deviceAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &deviceAddr, 0, nil,
                    &deviceSize, &deviceID) == noErr, deviceID != 0 {
                    var frames = UInt32(512)
                    var framesAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyBufferFrameSize,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain)
                    AudioObjectSetPropertyData(
                        deviceID, &framesAddr, 0, nil,
                        UInt32(MemoryLayout<UInt32>.size), &frames)
                }
                if Self.inputTapInstalled {
                    self.tapInstalled = true
                    Self.activeInputMeter = self
                    do {
                        if !self.engine.isRunning { try self.engine.start() }
                        Self.rearmAfterRestart()
                        self.running = true
                        self.startInFlight = false
                        self.settle()
                    } catch {
                        self.startInFlight = false
                        self.settle()
                    }
                    return
                }
                // AVAudioEngine throws an ObjC exception (and aborts the app)
                // when installTap sees an existing tap; Swift cannot catch it.
                // Always remove the bus tap after stopping the previous owner,
                // even if our bookkeeping flag was lost during a route change.
                input.removeTap(onBus: 0)
                Self.inputTapInstalled = false
                self.tapInstalled = false
                // Voice processing once per process, and before the playback
                // bus below connects: enable it while the engine is stopped —
                // connecting first materializes the output graph at the
                // pre-VPIO format and `setVoiceProcessingEnabled` then raises
                // an ObjC exception Swift cannot catch (the iOS lesson,
                // docs/troubleshooting.md "SIGABRT"). On by default (the iOS
                // AEC fix); `IDFON_MACOS_AEC=0` opts out for devices whose mic
                // delivers silence through VPIO (e.g. the LG UltraFine Display
                // Audio USB mic) — the 1s RMS log shows that immediately.
                if !Self.voiceProcessingTried {
                    // Once per process: the tap is process-sticky, so the mode
                    // is fixed here. Skipped on the stereo (headset) route —
                    // VPIO would mono-downmix the tap (docs/stereo-calls.md).
                    Self.voiceProcessingTried = true
                    if Self.stereoCaptureForCall() {
                        Self.log("idfon audio meter: voice-processing skipped (headset route, stereo capture)")
                    } else if ProcessInfo.processInfo.environment["IDFON_MACOS_AEC"] == "0" {
                        Self.log("idfon audio meter: voice-processing off (IDFON_MACOS_AEC=0)")
                    } else {
                        do {
                            try input.setVoiceProcessingEnabled(true)
                            // Same ducking posture as iOS `AudioIO`: VPIO must
                            // not duck or pump the app's own playback. The
                            // knob is macOS 14.2+; below that VPIO keeps its
                            // default ducking — only that posture is missing,
                            // echo cancellation itself is unaffected.
                            if #available(macOS 14.2, *) {
                                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                                    enableAdvancedDucking: false, duckingLevel: .min)
                            }
                            Self.log("idfon audio meter: voice-processing enabled")
                        } catch {
                            Self.log("idfon audio meter: voice-processing unsupported: \(error.localizedDescription)")
                        }
                    }
                }
                // Playback bus: attach the player, then connect it after voice
                // processing (see above). One node per process, like the tap.
                if !Self.playbackAttached {
                    Self.playbackAttached = true
                    Self.inputEngine.attach(Self.playbackPlayer)
                    Self.inputEngine.connect(Self.playbackPlayer, to: Self.inputEngine.mainMixerNode, format: nil)
                }
                let format = input.outputFormat(forBus: 0)
                if self.pushToEncoder {
                    let outputFormat = self.pipelineFormat()
                    self.converter = AVAudioConverter(from: format, to: outputFormat)
                    self.outputFormat = outputFormat
                    self.pushedBuffers = 0
                    self.callbackBuffers = 0
                    self.windowSamples = 0
                    self.windowSumSquares = 0
                    self.windowPeak = 0
                    if self.converter == nil {
                        // Non-standard hardware format: keep metering but drop the
                        // push rather than publish wrong-speed audio.
                        idfonLog("idfon push: no converter for \(format); call stays on mic capture")
                        self.pushToEncoder = false
                    }
                }
                Self.log("idfon audio meter installing tap format=\(format)")
                // installTap raises an uncapturable ObjC exception (and aborts
                // the app) on an invalid format: at call start macOS is often
                // mid-route-change and inputNode reports 0 Hz/0 ch. Retry once
                // the device settles instead of crashing or losing the capture.
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    Self.log("idfon audio meter: invalid input format \(format); retrying")
                    if generation < 4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self, self.startGeneration == generation,
                                  !self.running else {
                                self?.startInFlight = false
                                self?.settle()
                                return
                            }
                            self.startInFlight = false
                            self.start { self.settle() }
                        }
                    } else {
                        self.startInFlight = false
                        self.settle()
                    }
                    return
                }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak owner = self] buffer, time in
                    guard let owner else { return }
                    owner.callbackBuffers += 1
                    if owner.callbackBuffers <= 3 || owner.callbackBuffers % 100 == 0 {
                        Self.log("idfon call capture: tap callback buffer=\(owner.callbackBuffers) push=\(owner.pushToEncoder) frames=\(buffer.frameLength)")
                    }
                    let rms = Self.rms(buffer)
                    for wave in owner.views { wave.view?.add(amplitude: Float(min(rms * 12, 1))) }
                    if owner.pushToEncoder { owner.push(buffer) }
                    Self.fanOutCapture(buffer, at: time)
                }
                self.tapInstalled = true
                Self.inputTapInstalled = true
                Self.activeInputMeter = self
                do {
                    try self.engine.start()
                    self.installAudioObservers()
                    Self.rearmAfterRestart() // playback dropped by a recovery stop
                    self.running = true
                    self.startInFlight = false
                    Self.log("idfon audio meter engine started")
                    self.settle()
                } catch {
                    Self.log("idfon audio meter failed: \(error.localizedDescription)")
                    self.startInFlight = false
                    self.settle()
                }
            }
        }
    }

    func startForCall(sampleRate: Int = 48_000, channels: Int = 0) async -> Bool {
        // 0 = follow the call's audio mode (the panel's radio group).
        configureForCall(
            sampleRate: sampleRate,
            channels: channels == 0 ? Self.captureChannelsForCall() : channels)
        return await withCheckedContinuation { continuation in
            start(sampleRate: sampleRate) {
                continuation.resume(returning: self.running)
            }
        }
    }

    /// Switch the push channel count (a mode change re-publishes the leg):
    /// the converter rebuilds on the next buffer.
    func retarget(channels: Int) {
        targetChannels = max(1, min(2, channels))
        converter = nil
        outputFormat = nil
    }

    /// Calls queued start completions; they read `running` for the outcome.
    private func settle() {
        let pending = pendingStarts
        pendingStarts = []
        pending.forEach { $0() }
    }

    func stop() {
        startGeneration += 1
        startInFlight = false // a stop during an in-flight start discards it
        guard running || tapInstalled else { pendingStarts = []; return }
        // The tap stays installed (see start()); only the engine stops, so no
        // buffers flow while idle and nothing ever re-installs the tap.
        if Self.activeInputMeter === self { Self.activeInputMeter = nil }
        engine.stop()
        converter = nil
        outputFormat = nil
        removeAudioObservers()
        running = false
        settle() // pending start callers observe running=false
        // Hand the shared tap to any remaining capture observers: a page's
        // meter stopping must never starve the STT components (the
        // single-input-owner consolidation).
        if self !== Self.shared, !Self.captureObservers.allObjects.isEmpty {
            Self.headlessRunning = true
            Self.shared.start()
        }
    }

    private func installAudioObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            Self.dropping = true // a recovery stop: playback re-arms on restart
            self.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.start(sampleRate: self.targetSampleRate)
            }
        }
    }

    private func removeAudioObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver); self.interruptionObserver = nil }
    }

    deinit {
        stop()
        removeAudioObservers()
    }

    /// Converts a hardware-format tap buffer to the ingest format and hands it
    /// to the dylib. `.noDataNow` after one buffer lets the converter retain its
    /// resampler state for the next tap.
    private func push(_ buffer: AVAudioPCMBuffer) {
        if converter == nil {
            let format = pipelineFormat()
            outputFormat = format
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter, let outputFormat else { return }
        let ratio = Double(targetSampleRate) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let planes = out.floatChannelData else { return }
        let channel = planes[0]
        let count = Int(out.frameLength)
        var rawSum = 0.0
        var rawPeak = 0.0
        for index in 0..<count {
            let sample = Double(channel[index])
            rawSum += sample * sample
            rawPeak = max(rawPeak, abs(sample))
        }
        let rawRMS = (rawSum / Double(count)).squareRoot()
        windowSamples += count
        windowSumSquares += rawSum
        windowPeak = max(windowPeak, rawPeak)
        if windowSamples >= targetSampleRate {
            let windowRMS = (windowSumSquares / Double(windowSamples)).squareRoot()
            Self.log("idfon audio meter 1s window samples=\(windowSamples) rms=\(windowRMS) peak=\(windowPeak)")
            windowSamples = 0
            windowSumSquares = 0
            windowPeak = 0
        }
        // Do not apply fixed gain here: multiplying microphone samples by 2
        // followed by hard clipping turns loud speech into harsh distortion.
        // Keep the captured signal unchanged until a measured normalization
        // policy exists.
        pushedBuffers += 1
        if pushedBuffers <= 5 || pushedBuffers % 100 == 0 {
            idfonLog("idfon audio levels buffer=\(pushedBuffers) raw_rms=\(rawRMS) raw_peak=\(rawPeak)")
        }
        if pushedBuffers <= 5 || pushedBuffers % 100 == 0 {
            Self.log("idfon audio meter push buffer=\(pushedBuffers) samples=\(count) rms=\(rawRMS) peak=\(rawPeak)")
        }
        if targetChannels == 1 {
            media_audio_push_samples(channel, count)
        } else {
            // Interleaved f32: the encoder's native layout (`Format::F32`).
            var interleaved = [Float](repeating: 0, count: count * targetChannels)
            for frame in 0..<count {
                for index in 0..<targetChannels {
                    interleaved[frame * targetChannels + index] = planes[index][frame]
                }
            }
            interleaved.withUnsafeBufferPointer { buffer in
                media_audio_push_frames(buffer.baseAddress, count, UInt32(targetChannels))
            }
        }
    }

    /// Schedule one decoded remote-call chunk (`AudioPlaybackSink`) on the
    /// shared engine's playback bus without awaiting: chunks queue back to
    /// back and must never wait on a previous chunk's completion callback.
    /// This bus is the AEC reference — remote audio anywhere else cannot be
    /// echo-cancelled (docs/audio-media.md).
    static func playStream(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            guard inputEngine.isRunning else {
                log("idfon audio meter: stream play dropped engine idle")
                return
            }
            guard let converted = convert(buffer, to: playbackPlayer.outputFormat(forBus: 0)) else {
                log("idfon audio meter: stream play dropped convert failed")
                return
            }
            PlaybackBus.notify(converted) // the second ear
            playbackPlayer.scheduleBuffer(converted, at: nil, options: [], completionHandler: nil)
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    /// One-shot playback on the shared bus (cues, TTS chunks). This bus is the
    /// AEC reference — anything played elsewhere (AVAudioPlayer,
    /// AVSpeechSynthesizer's own output) is echo the mic cannot cancel.
    static func play(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard inputEngine.isRunning else {
                log("idfon audio meter: play dropped engine idle")
                completion?()
                return
            }
            guard let converted = convert(buffer, to: playbackPlayer.outputFormat(forBus: 0)) else {
                log("idfon audio meter: play dropped convert failed")
                completion?()
                return
            }
            PlaybackBus.notify(converted) // the second ear
            let id = UUID()
            inFlightOneShots[id] = (converted, completion)
            scheduleOneShot(id: id, buffer: converted, completion: completion)
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    private static func scheduleOneShot(id: UUID, buffer: AVAudioPCMBuffer, completion: (() -> Void)?) {
        playbackPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: {
            if dropping { return } // a recovery stop: keep it for re-arm
            inFlightOneShots.removeValue(forKey: id)
            completion?()
        })
    }

    /// Re-arm what a recovery stop discarded (the engine self-stop class).
    /// Deliberate stops keep their complete-and-drop semantics.
    static func rearmAfterRestart() {
        guard dropping else { return }
        dropping = false
        if let loop = activeLoop {
            playbackPlayer.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
            log("idfon audio meter: loop re-armed after engine restart")
        }
        for (id, entry) in inFlightOneShots {
            scheduleOneShot(id: id, buffer: entry.buffer, completion: entry.completion)
            log("idfon audio meter: one-shot re-armed after engine restart")
        }
        if (activeLoop != nil || !inFlightOneShots.isEmpty), !playbackPlayer.isPlaying {
            playbackPlayer.play()
        }
    }

    /// A looping cue (the ring). Fed to the second ear once (its repeats are
    /// the same samples).
    static func playLooping(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            guard inputEngine.isRunning else {
                log("idfon audio meter: loop dropped engine idle")
                return
            }
            guard let converted = convert(buffer, to: playbackPlayer.outputFormat(forBus: 0)) else {
                log("idfon audio meter: loop dropped convert failed")
                return
            }
            PlaybackBus.notify(converted) // the second ear
            activeLoop = converted
            playbackPlayer.scheduleBuffer(converted, at: nil, options: [.loops], completionHandler: nil)
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    /// Stop everything on the bus (a tone switch or barge).
    static func stopPlayback() {
        DispatchQueue.main.async {
            activeLoop = nil
            inFlightOneShots.removeAll() // deliberate stop: callers complete, audio is dropped
            playbackPlayer.stop()
            if inputEngine.isRunning { playbackPlayer.play() } // ready for the next schedule
        }
    }

    /// Decode wav bytes (PCM s16/float) into a buffer for the shared bus.
    static func buffer(wav data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idfon-audio-bus.wav")
        guard (try? data.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        return input
    }

    /// Convert `buffer` to `target`; returns it unchanged when it already matches.
    private static func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
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
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
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

    /// RMS of the first channel.
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum = 0.0
        for frame in 0..<frames {
            let sample = Double(data[frame])
            sum += sample * sample
        }
        return (sum / Double(frames)).squareRoot()
    }
}