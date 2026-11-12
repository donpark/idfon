import Foundation

/// The quiet clock from RealtimeVAD (KoljaB/RealtimeVAD, MIT): every 10 ms the
/// block's RMS is compared with the room's own noise level, so "the speaker
/// went quiet" is measured in audio time instead of in recognizer-text time.
///
/// The clock decides nothing itself. `VoicePromptSegmenter` uses its timings
/// for the opt-in early end (off by default) and for the calibration marker;
/// the text-gap fallback and recognizer finals stay authoritative.
///
/// Not thread-safe: drive it from the main thread only.
final class QuietClock {
    /// RealtimeVAD defaults (SPEC.md): 10 ms blocks, −54 dBFS floor, noise
    /// +15 dB, speech −15 dB, 64 ms of loud audio re-arms a pause.
    private let blockSeconds = 0.01
    private let quietRms = 0.002
    private let noiseMarginDb = 15.0
    private let speechMarginDb = 15.0
    private let rearmSeconds = 0.064

    /// A pause started at this audio time (seconds processed so far).
    var onPause: ((TimeInterval) -> Void)?
    /// Quiet seconds since that pause, then the loud seconds that re-armed it.
    var onResume: ((TimeInterval, TimeInterval) -> Void)?

    private var pending: [Float] = []
    private var rate: Double = 0
    private var blockSamples = 0
    private var rearmSamples = 0
    private var noiseDb: Double?
    private var speechDb: Double?
    private var thresholdRms = 0.0
    private var inSegment = false
    private var pauseStart: TimeInterval?
    private var loudStart: TimeInterval?
    private var loudSamples = 0
    private var processed: TimeInterval = 0

    init() { thresholdRms = quietRms }

    /// The current segment's speech began (the recognizer produced text).
    func begin() {
        inSegment = true
        pauseStart = nil
        loudStart = nil
        loudSamples = 0
    }

    /// The segment committed or was dropped: stop reporting pauses.
    func end() {
        inSegment = false
        pauseStart = nil
        loudStart = nil
        loudSamples = 0
    }

    /// Quiet seconds in the open pause (0 when speech is running).
    var quietSeconds: TimeInterval {
        guard let pauseStart else { return 0 }
        return max(0, processed - pauseStart)
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        noiseDb = nil
        speechDb = nil
        thresholdRms = quietRms
        inSegment = false
        pauseStart = nil
        loudStart = nil
        loudSamples = 0
        processed = 0
    }

    func feed(_ samples: [Float], sampleRate: Double) {
        guard sampleRate > 0, !samples.isEmpty else { return }
        if rate != sampleRate {
            rate = sampleRate
            blockSamples = max(1, Int((blockSeconds * sampleRate).rounded()))
            rearmSamples = max(1, Int((rearmSeconds * sampleRate).rounded()))
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(contentsOf: samples)
        var i = 0
        while pending.count - i >= blockSamples {
            process(pending[i..<(i + blockSamples)])
            i += blockSamples
        }
        if i > 0 { pending.removeFirst(i) }
    }

    private func process(_ block: ArraySlice<Float>) {
        var power: Float = 0
        for v in block { power += v * v }
        let rms = Double((power / Float(block.count)).squareRoot())
        let db = max(-100.0, 20.0 * log10(max(rms, 1e-9)))
        let quiet = rms <= thresholdRms
        updateLevels(db: db, quiet: quiet)

        let blockStart = processed
        processed += Double(block.count) / rate
        guard inSegment else { return }
        if quiet {
            loudSamples = 0
            loudStart = nil
            if pauseStart == nil {
                pauseStart = blockStart
                onPause?(blockStart)
            }
        } else if let start = pauseStart {
            if loudStart == nil { loudStart = blockStart }
            loudSamples += block.count
            if loudSamples >= rearmSamples, let loudStart {
                onResume?(loudStart - start, Double(loudSamples) / rate)
                pauseStart = nil
            }
        }
    }

    /// Learn the room and speech levels; the quiet threshold sits between them.
    /// Same rules as the reference: noise rises slowly, is learned only from
    /// audio that is not speech, and never squeezes the threshold past speech
    /// − 15 dB or below the −54 dBFS floor.
    private func updateLevels(db: Double, quiet: Bool) {
        if inSegment {
            if quiet {
                noiseDb = move(noiseDb, toward: db, limit: 1.0)
            } else if let noiseDb, db > noiseDb + noiseMarginDb {
                speechDb = move(speechDb, toward: db, limit: 1.0)
            }
        } else if db > -90 { // skip gates/digital silence
            if let n = noiseDb {
                noiseDb = db <= n ? db : n + min(db - n, 3.0 * blockSeconds)
            } else {
                noiseDb = db
            }
        }
        let floorDb = 20.0 * log10(quietRms)
        var db2 = floorDb
        if let n = noiseDb { db2 = max(db2, n + noiseMarginDb) }
        if let s = speechDb { db2 = max(floorDb, min(db2, s - speechMarginDb)) }
        thresholdRms = pow(10.0, db2 / 20.0)
    }

    private func move(_ value: Double?, toward target: Double, limit: Double) -> Double {
        guard let value else { return target }
        return value + max(-limit, min(limit, target - value))
    }
}
