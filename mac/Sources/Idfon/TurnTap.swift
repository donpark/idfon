import AVFAudio
import Foundation

/// Captured samples (mono f32 at the device rate) -> 16 kHz hops of `hopSize`
/// (5120 = TurnRuntime.hopSamples = 320 ms) for the turn engine. Polyphase
/// resampling via AVAudioConverter; partial hops accumulate across feeds. Not
/// thread-safe: call from one queue (the tap's is fine; consumers hop threads
/// themselves — see TurnShadow).
final class TurnTap {
    /// Full 16 kHz hops as they complete.
    var onHop: (([Float]) -> Void)?
    private let hop: Int
    private var converter: AVAudioConverter?
    private var inputRate = 0.0
    private var pending: [Float] = []
    private let outFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    init(hopSize: Int) {
        self.hop = hopSize
    }

    /// Feed captured samples (mono f32 at `rate`); full hops come back on
    /// `onHop` as they complete.
    func feed(_ samples: [Float], rate: Double) {
        guard !samples.isEmpty else { return }
        if rate != inputRate {
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            inputRate = rate
            pending.removeAll()
        }
        guard let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            inBuf.floatChannelData![0].update(from: p.baseAddress!, count: samples.count)
        }
        var supplied = false
        // Bounded: the converter drains its resampler tail in a few passes. A
        // converter stuck returning `.haveData` must not spin this loop — it
        // fed the 2026-10-22 hangup watchdog kill (CPU resource, bug 202).
        for _ in 0..<32 {
            let capacity = AVAudioFrameCount(Double(samples.count) * 16000.0 / rate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                return
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            }
            while pending.count >= hop {
                onHop?(Array(pending.prefix(hop)))
                pending.removeFirst(hop)
            }
            if status != .haveData {
                if let error {
                    NSLog("turn-tap: convert %@", error.localizedDescription)
                }
                return
            }
            if out.frameLength == 0 { return } // `.haveData` with nothing: done
        }
    }
}
