import UIKit
import AVFAudio

/// Messages-style dotted waveform. Low amplitudes render as small dots on the
/// center line; louder ones grow into vertical bars around it. Two modes:
/// live (scrolling, fed per-sample by AudioMeter) and static (fixed samples,
/// e.g. a recorded file).
final class LiveWaveformView: UIView {
    enum Mode {
        case live
        case staticSamples([Float])
    }

    var style: Style = .recording {
        didSet { setNeedsDisplay() }
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
        backgroundColor = .clear
        contentMode = .redraw
    }

    func startLive() {
        mode = .live
        liveSamples = .init(repeating: 0, count: barCount)
        setNeedsDisplay()
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
                self.setNeedsDisplay()
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard UIGraphicsGetCurrentContext() != nil else { return }
        lock.lock()
        let snapshot: [Float]
        switch mode {
        case .live: snapshot = liveSamples
        case .staticSamples(let samples): snapshot = samples
        }
        lock.unlock()

        let color = style == .recording ? UIColor.systemRed : UIColor.systemGray
        let playedColor = style == .recording ? color : UIColor.darkGray
        color.setFill()

        let count = CGFloat(max(snapshot.count, 1))
        let slot = rect.width / count
        let dotDiameter = min(slot * 0.55, 3)
        let midY = rect.midY

        for (index, amplitude) in snapshot.enumerated() {
            let x = CGFloat(index) * slot + slot / 2
            let fraction = count > 0 ? Double(index) / Double(snapshot.count) : 0
            let drawColor = mode.isStatic && fraction <= progress ? playedColor : color
            drawColor.setFill()
            if amplitude < 0.08 {
                // idle dot on the center line
                let dot = CGRect(x: x - dotDiameter / 2, y: midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
                UIBezierPath(ovalIn: dot).fill()
            } else {
                // bar growing symmetrically around the center line
                let barWidth = max(dotDiameter, 2)
                let height = max(CGFloat(amplitude) * rect.height * 0.9, dotDiameter)
                let bar = UIBezierPath(roundedRect: CGRect(x: x - barWidth / 2, y: midY - height / 2, width: barWidth, height: height), cornerRadius: barWidth / 2)
                bar.fill()
            }
        }
    }
}

private extension LiveWaveformView.Mode {
    var isStatic: Bool {
        if case .staticSamples = self { return true }
        return false
    }
}

/// Mic amplitude meter for the call screen: taps the session input and feeds
/// normalized RMS to a LiveWaveformView. Display-only — the daemon owns the
/// call's capture pipeline (docs/native-shells-plan.md "call screen contract").
final class AudioMeter {
    private let engine = AVAudioEngine()
    private weak var view: LiveWaveformView?
    private(set) var running = false

    init(view: LiveWaveformView) {
        self.view = view
    }

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            guard granted, let self, !self.running else { return }
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    let rms = Self.rms(buffer)
                    self?.view?.add(amplitude: Float(min(rms * 12, 1)))
                }
                try self.engine.start()
                self.running = true
            } catch {
                NSLog("idfon audio meter failed: \(error.localizedDescription)")
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
