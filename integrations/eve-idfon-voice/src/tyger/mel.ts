// Mel features: the exact NemotronAsrStreamingFeatureExtractor pipeline,
// ported from ports/tyger-swift/Sources/TygerVoice/MelFeatures.swift (which is
// validated ≤2e-3 against the Python extractor) so the TS runtime computes the
// model's input identically. Parity: test/mel.test.ts replays
// ports/tyger-swift/Tests/TygerVoiceTests/fixtures.json.
//
// Pipeline: preemphasis (0.97) -> center STFT 512/160 with symmetric Hann(400)
// centered in 512 -> power spectrum -> slaney mel (kMelFilters) -> log(x + 2^-24)
// -> the extractor's mask: frames >= floor(L/160) are zeros.

import { kMelFilters } from "./mel-filters.ts";

export const sampleRate = 16000;
export const hopLength = 160;
export const nFFT = 512;
export const winLength = 400;
export const nMels = 128;
export const preemphasis = 0.97;
export const logGuard = 2 ** -24;

export interface MelResult {
  features: number[][]; // frames x nMels
  validFrames: number;
}

/// In-place iterative radix-2 FFT on separate re/im arrays (length must be 2^k).
function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k];
        const ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

/// torch.hann_window(winLength, periodic: false), centered in `total` (zeros on both sides).
function hannSymmetric(winLength: number, total: number): Float64Array {
  const w = new Float64Array(total);
  const off = (total - winLength) / 2;
  for (let n = 0; n < winLength; n++) {
    w[off + n] = 0.5 * (1 - Math.cos((2 * Math.PI * n) / (winLength - 1)));
  }
  return w;
}

const WINDOW = hannSymmetric(winLength, nFFT);

/// (frames x nMels) log-mel features and the extractor's valid-frame count.
export function process(audio: ArrayLike<number>): MelResult {
  const n = audio.length;
  const validFrames = Math.floor(n / hopLength);
  if (n === 0) return { features: [], validFrames: 0 };

  // 1. preemphasis (y[0] = x[0])
  const y = new Float64Array(n);
  y[0] = audio[0];
  for (let t = 1; t < n; t++) y[t] = audio[t] - preemphasis * audio[t - 1];

  // 2. center pad + frames
  const half = nFFT / 2;
  const padded = new Float64Array(half + n + half);
  padded.set(y, half);
  const nFrames = Math.floor(n / hopLength) + 1;

  const features: number[][] = [];
  const re = new Float64Array(nFFT);
  const im = new Float64Array(nFFT);
  for (let f = 0; f < nFrames; f++) {
    const start = f * hopLength;
    for (let i = 0; i < nFFT; i++) {
      re[i] = padded[start + i] * WINDOW[i];
      im[i] = 0;
    }
    fft(re, im);
    const row = new Array<number>(nMels).fill(0);
    if (f < validFrames) {
      for (let m = 0; m < nMels; m++) {
        let acc = 0;
        const base = m * (nFFT / 2 + 1);
        for (let k = 0; k < nFFT / 2 + 1; k++) {
          acc += kMelFilters[base + k] * (re[k] * re[k] + im[k] * im[k]);
        }
        row[m] = Math.log(acc + logGuard);
      }
    }
    features.push(row);
  }
  return { features, validFrames };
}
