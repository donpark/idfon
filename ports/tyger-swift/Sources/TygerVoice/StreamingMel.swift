import Foundation

/// Incremental log-mel for the streaming turn prefix: the same rows
/// ``MelFeatures/process(_:)`` computes for the whole signal, emitted as audio
/// arrives, so a 320 ms hop can be fed to a cache-aware encoder without
/// re-extracting an 8 s window every time.
///
/// The extractor is `center=True`: row `g`'s 512-sample window is
/// `[g*160-256, g*160+256)`, so a row exists only once its right halfframe has
/// arrived (16 ms after the row's own 10 ms starts). A row is never emitted with
/// a partially zero right window — that row is not audio — and the extractor's
/// own trailing masked row has no streaming counterpart. Rows before zero and
/// after the last fed sample are the extractor's zero padding, as in `process`.
public final class StreamingMel {
    private let kernel = MelFeatures.MelKernel()
    /// Audio from `sampleBase` onward; trimmed to what the next row still needs.
    private var samples: [Float] = []
    private var sampleBase = 0
    private var nextRow = 0

    public init() {}

    /// Whole rows emitted so far.
    public var rowCount: Int { nextRow }

    /// Append audio and return every row that became complete, oldest first.
    public func append(_ audio: [Float]) -> [[Float]] {
        samples.append(contentsOf: audio)
        let half = MelFeatures.nFFT / 2
        let hop = MelFeatures.hopLength
        var rows: [[Float]] = []
        while true {
            let start = nextRow * hop - half            // first sample of the row's window
            let end = start + MelFeatures.nFFT
            guard end <= sampleBase + samples.count else { break }
            // Pre-emphasis needs x[t-1]; index 0 of this scratch is that sample.
            var x = [Float](repeating: 0, count: MelFeatures.nFFT + 1)
            for i in 0...MelFeatures.nFFT {
                let t = start - 1 + i
                if t >= sampleBase && t < sampleBase + samples.count {
                    x[i] = samples[t - sampleBase]
                }
            }
            var win = [Float](repeating: 0, count: MelFeatures.nFFT)
            for i in 0..<MelFeatures.nFFT {
                // y[0] = x[0]: x[-1] is the extractor's zero padding, so the
                // general formula already gives the special case.
                win[i] = x[i + 1] - MelFeatures.preemphasis * x[i]
            }
            rows.append(kernel.row(win))
            nextRow += 1
            // Keep only what the next row's window (plus one pre-emphasis sample) needs.
            let keepFrom = nextRow * hop - half - 1
            if keepFrom > sampleBase {
                samples.removeFirst(keepFrom - sampleBase)
                sampleBase = keepFrom
            }
        }
        return rows
    }

    /// Back to the start of a stream: the encoder caches restart with it.
    public func reset() {
        samples.removeAll()
        sampleBase = 0
        nextRow = 0
    }
}
