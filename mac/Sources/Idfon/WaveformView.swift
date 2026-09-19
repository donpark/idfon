import AppKit
import AVFoundation
import CIdfon

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
/// With `pushToEncoder` set, the same tap also feeds the live publisher's
/// generic audio ingest (`media_audio_push_samples`) as 48 kHz mono f32. Only
/// the live-call meter does so: in the dylib's "push" mode the Rust side does
/// not open the mic, so this tap is the call's sole capture and its levels are
/// the very samples the peer hears (issue #7). Memo meters leave it off.
final class AudioMeter {
    static let shared = AudioMeter()
    private static let logQueue = DispatchQueue(label: "idfon.audio-meter-log")
    private static func log(_ message: String) {
        NSLog("\(message)")
        logQueue.async {
            let url = URL(fileURLWithPath: "/tmp/idfon-audio-\(ProcessInfo.processInfo.processIdentifier).log")
            let line = "\(Date()) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path), let file = try? FileHandle(forWritingTo: url) {
                    try? file.seekToEnd()
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
    private var tapInstalled = false
    private var startGeneration = 0
    private static weak var activeInputMeter: AudioMeter?
    private static var inputTapInstalled = false

    /// Opt in to feeding the call's encoder as well as the waveform. In the
    /// dylib's "push" mode the Rust side does not open the mic, so this tap is
    /// the call's sole capture; leaving it off (memo meters) only displays.
    var pushToEncoder = false

    /// The ingest format the dylib's `PushAudioSource` expects.
    private static let pipelineFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    /// Hardware format -> ingest format; keeps its resampler state across taps.
    private var converter: AVAudioConverter?
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

    func start() {
        Self.log("idfon audio meter start requested running=\(running) tap=\(tapInstalled) push=\(pushToEncoder)")
        guard !running, !tapInstalled else { return }
        startGeneration += 1
        let generation = startGeneration
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Self.log("idfon audio meter permission granted=\(granted)")
            guard granted, let self, !self.running else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.startGeneration,
                      !self.running, !self.tapInstalled else { return }
                // The input bus accepts only one tap process-wide. This can be
                // hit during device changes when an old meter's permission
                // callback arrives after the UI has created the replacement.
                if let active = Self.activeInputMeter, active !== self { active.stop() }
                let input = self.engine.inputNode
                if Self.inputTapInstalled {
                    input.removeTap(onBus: 0)
                    Self.inputTapInstalled = false
                }
                self.tapInstalled = false
                let format = input.outputFormat(forBus: 0)
                if self.pushToEncoder {
                    self.converter = AVAudioConverter(from: format, to: Self.pipelineFormat)
                self.pushedBuffers = 0
                self.callbackBuffers = 0
                self.windowSamples = 0
                self.windowSumSquares = 0
                self.windowPeak = 0
                    if self.converter == nil {
                        // Non-standard hardware format: keep metering but drop the
                        // push rather than publish wrong-speed audio.
                        NSLog("idfon push: no converter for \(format); call stays on mic capture")
                        self.pushToEncoder = false
                    }
                }
                Self.log("idfon audio meter installing tap format=\(format)")
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak owner = self] buffer, _ in
                    guard let owner else { return }
                    owner.callbackBuffers += 1
                    if owner.callbackBuffers <= 3 || owner.callbackBuffers % 100 == 0 {
                        Self.log("idfon call capture: tap callback buffer=\(owner.callbackBuffers) push=\(owner.pushToEncoder) frames=\(buffer.frameLength)")
                    }
                    let rms = Self.rms(buffer)
                    for wave in owner.views { wave.view?.add(amplitude: Float(min(rms * 12, 1))) }
                    if owner.pushToEncoder { owner.push(buffer) }
                }
                self.tapInstalled = true
                Self.inputTapInstalled = true
                Self.activeInputMeter = self
                do {
                    try self.engine.start()
                    self.installAudioObservers()
                    self.running = true
                    Self.log("idfon audio meter engine started")
                } catch {
                    Self.log("idfon audio meter failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        startGeneration += 1
        guard running || tapInstalled else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            Self.inputTapInstalled = false
        }
        if Self.activeInputMeter === self { Self.activeInputMeter = nil }
        engine.stop()
        converter = nil
        removeAudioObservers()
        running = false
    }

    private func installAudioObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.stop()
            self.start()
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
        guard let converter else { return }
        let ratio = Self.pipelineFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.pipelineFormat, frameCapacity: capacity) else { return }
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
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
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
        if windowSamples >= 48_000 {
            let windowRMS = (windowSumSquares / Double(windowSamples)).squareRoot()
            Self.log("idfon audio meter 1s window samples=\(windowSamples) rms=\(windowRMS) peak=\(windowPeak)")
            windowSamples = 0
            windowSumSquares = 0
            windowPeak = 0
        }
        // Keep the current gain only as an explicit measurement condition; do
        // not claim normalization until sender/receiver levels are compared.
        for index in 0..<count {
            channel[index] = max(-1, min(1, channel[index] * 2))
        }
        var outputPeak = 0.0
        for index in 0..<count { outputPeak = max(outputPeak, abs(Double(channel[index]))) }
        pushedBuffers += 1
        if pushedBuffers <= 5 || pushedBuffers % 100 == 0 {
            NSLog("idfon audio levels buffer=\(pushedBuffers) raw_rms=\(rawRMS) raw_peak=\(rawPeak) post_gain_rms=\(rawRMS * 2) post_gain_peak=\(outputPeak) clipped=\(outputPeak >= 0.999)")
        }
        if pushedBuffers <= 5 || pushedBuffers % 100 == 0 {
            Self.log("idfon audio meter push buffer=\(pushedBuffers) samples=\(count) raw_rms=\(rawRMS) post_gain_peak=\(outputPeak)")
        }
        media_audio_push_samples(channel, count)
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