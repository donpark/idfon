// Audio helpers for the TypeScript voice tools: Ogg Opus → s16le PCM, and
// WAV wrap/parse. Kept dependency-light: the Opus decoder is imported at
// runtime so the agent builds without it installed.

import { optionalImport } from "./optional";

export const RATE = 24_000; // s16le mono 24 kHz, the call/memo plane

/** Ogg Opus (48 kHz) → s16le mono 24 kHz. Needs `ogg-opus-decoder` installed. */
export async function opusToPcm24k(opus: Uint8Array): Promise<Buffer> {
  const pkg = "ogg-opus-decoder";
  let module: Record<string, unknown>;
  try {
    module = await optionalImport(pkg);
  } catch {
    throw new Error(`install '${pkg}' to decode voice memos`);
  }
  const { OggOpusDecoder } = module as unknown as {
    OggOpusDecoder: new () => {
      ready: Promise<void>;
      decodeFile(bytes: Buffer): Promise<{ samplesDecoded: number; channelData: Float32Array[] }>;
      free(): Promise<void>;
    };
  };
  const decoder = new OggOpusDecoder();
  await decoder.ready;
  const decoded = await decoder.decodeFile(Buffer.from(opus));
  await decoder.free();
  if (decoded.samplesDecoded === 0) throw new Error("no audio decoded from recording");
  const samples = decoded.channelData[0];
  const out = Buffer.alloc(Math.ceil(samples.length / 2) * 2);
  for (let i = 0, j = 0; i + 1 < samples.length; i += 2, j += 1) {
    // ponytail: pick-every-other decimation, no anti-alias filter; swap in a
    // real resampler if a model mishears sibilants.
    const v = (samples[i] + samples[i + 1]) / 2;
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), j * 2);
  }
  return out;
}

/** s16le mono PCM → 44-byte WAV container. */
export function wavWrap(pcm: Buffer, rate = RATE): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

/** WAV → s16le samples (falls back to the raw bytes when there is no RIFF). */
export function wavToPcm(bytes: Buffer): Buffer {
  if (bytes.length < 44 || bytes.subarray(0, 4).toString("latin1") !== "RIFF") return bytes;
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const id = bytes.subarray(offset, offset + 4).toString("latin1");
    const size = bytes.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "data") return bytes.subarray(start, Math.min(start + size, bytes.length));
    offset = start + size + (size & 1);
  }
  return bytes.subarray(44);
}
