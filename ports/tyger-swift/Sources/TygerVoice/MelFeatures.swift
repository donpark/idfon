import Accelerate
import Foundation

/// Mel features: the exact NemotronAsrStreamingFeatureExtractor pipeline
/// (transformers' feature_extraction_nemotron_asr_streaming.py), ported for the
/// on-device runtime. Parity: `scripts/tyger-swift-fixtures.py` dumps the Python
/// extractor's output on scripted audio; `swift test` asserts it here.
///
/// Pipeline (verified against the extractor's source):
///   1. preemphasis on audio: y[0] = x[0], y[t] = x[t] - 0.97·x[t-1]
///   2. center=True STFT: 256 zeros each side (pad_mode "constant"), frames of
///      512 every 160 samples, window = symmetric Hann(400) centered in 512
///   3. power spectrum |X[k]|², k = 0..256
///   4. slaney mel (128 × 257, generated constant) × power
///   5. log(mel + 2^-24)   ("never normalizes" — the extractor's own comment)
///   6. the extractor's attention mask zeroes frames >= floor(L / 160); the model
///      sees those rows as zeros exactly as in the accepted parity path
public enum MelFeatures {
    public static let sampleRate = 16000
    public static let hopLength = 160
    public static let nFFT = 512
    public static let winLength = 400
    public static let nMels = 128
    public static let preemphasis: Float = 0.97
    public static let logGuard: Float = 0x1p-24 // 2^--24, the extractor's LOG_ZERO_GUARD_VALUE

    /// (frames × nMels) log-mel features, and the extractor's valid-frame count.
    public static func process(_ audio: [Float]) -> (features: [[Float]], validFrames: Int) {
        let n = audio.count
        let validFrames = n / hopLength // floor(L / hop): the attention mask's count
        guard n > 0 else { return ([], 0) }

        // 1. preemphasis
        var y = audio
        if n > 1 {
            for t in stride(from: n - 1, through: 1, by: -1) {
                y[t] = audio[t] - preemphasis * audio[t - 1]
            }
        }

        // 2. center pad + frames
        let half = nFFT / 2
        var padded = [Float](repeating: 0, count: half + n + half)
        padded.replaceSubrange(half..<(half + n), with: y)
        let nFrames = n / hopLength + 1
        let kernel = MelKernel()
        var out = [[Float]](repeating: [Float](repeating: 0, count: nMels), count: nFrames)

        for f in 0..<nFrames {
            let start = f * hopLength
            out[f] = kernel.row(Array(padded[start..<start + nFFT]))
            // 6. the extractor's mask: frames beyond validFrames are zeros
            if f >= validFrames {
                for m in 0..<nMels {
                    out[f][m] = 0
                }
            }
        }
        return (out, validFrames)
    }

    /// One mel row from one 512-sample (already padded, not pre-emphasized) window:
    /// steps 2-5 above. Shared by the whole-window extractor and ``StreamingMel`` so
    /// the streaming tier produces the same rows, not a re-derivation of them.
    final class MelKernel {
        private let setup: FFTSetup
        private let window: [Float]
        private let log2n: vDSP_Length
        private var frame: [Float]
        private var re: [Float]
        private var im: [Float]
        private var outRe: [Float]
        private var outIm: [Float]
        private var power: [Float]

        init() {
            log2n = vDSP_Length(log2(Float(nFFT)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = hannSymmetric(winLength: winLength, total: nFFT)
            frame = [Float](repeating: 0, count: nFFT)
            re = frame
            im = frame
            outRe = frame
            outIm = frame
            power = [Float](repeating: 0, count: nFFT / 2 + 1)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func row(_ samples: [Float]) -> [Float] {
            precondition(samples.count == nFFT)
            for i in 0..<nFFT {
                frame[i] = samples[i] * window[i]
            }
            for i in 0..<nFFT {
                re[i] = frame[i]
                im[i] = 0
            }
            re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    outRe.withUnsafeMutableBufferPointer { orp in
                        outIm.withUnsafeMutableBufferPointer { oip in
                            var input = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                                                        imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                            var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                            vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }
            for k in 0..<(nFFT / 2 + 1) {
                power[k] = outRe[k] * outRe[k] + outIm[k] * outIm[k]
            }
            // 3-4. slaney mel × power
            var row = [Float](repeating: 0, count: nMels)
            for m in 0..<nMels {
                var acc: Float = 0
                let base = m * (nFFT / 2 + 1)
                for k in 0..<(nFFT / 2 + 1) {
                    acc += kMelFilters[base + k] * power[k]
                }
                // 5. log with the guard
                row[m] = logf(acc + logGuard) // logf: .log() collides with Accelerate's BNNSGraph overload
            }
            return row
        }
    }

    /// torch.hann_window(length, periodic: false), centered in `total` (zeros on both sides).
    static func hannSymmetric(winLength: Int, total: Int) -> [Float] {
        var w = [Float](repeating: 0, count: total)
        let off = (total - winLength) / 2
        for n in 0..<winLength {
            w[off + n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(winLength - 1)))
        }
        return w
    }
}
