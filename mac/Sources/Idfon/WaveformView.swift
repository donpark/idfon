import AppKit
import AVFoundation

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
    static func amplitudes(url: URL, count: Int = 64) -> [Float] {
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
/// waveform via a closure. Display-only — the call's capture pipeline stays
/// in the daemon (cpal); this is a second, display-only mic client, which
/// macOS allows (mic capture is non-exclusive). Port of the iOS AudioMeter
/// minus AVAudioSession (doesn't exist on macOS).
final class AudioMeter {
    private let engine = AVAudioEngine()
    private weak var view: WaveformView?
    private(set) var running = false

    init(view: WaveformView) {
        self.view = view
    }

    func start() {
        guard !running else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted, let self, !self.running else { return }
            DispatchQueue.main.async {
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    let rms = Self.rms(buffer)
                    self?.view?.add(amplitude: Float(min(rms * 12, 1)))
                }
                do {
                    try self.engine.start()
                    self.running = true
                } catch {
                    NSLog("idfon audio meter failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
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