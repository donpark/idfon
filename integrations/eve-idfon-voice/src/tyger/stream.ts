// Stream glue shared by the tyger consumers (shadow, endpointer): the wire is
// 24 kHz s16 mono, the model's grid is 16 kHz.

export const EARS_RATE = 16000;
export const WIRE_RATE = 24000;

/// The tyger-relay's linear 24k->16k resampler (makeResampler), ported.
/// Stateful: `pos -= x.length` carries into the next chunk's index space.
export function makeResampler(rate = WIRE_RATE, earsRate = EARS_RATE): (x: ArrayLike<number>) => number[] {
  const step = rate / earsRate;
  let pos = -1;
  let prev = 0;
  return (x) => {
    const out: number[] = [];
    if (pos < -1) pos = 0; // a gap in the stream: start over here
    for (;;) {
      const p = Math.floor(pos);
      const i = p;
      if (i + 1 >= x.length) break;
      const a = i < 0 ? prev : x[i];
      const f = pos - p;
      out.push(a + (x[i + 1] - a) * f);
      pos += step;
    }
    prev = x[x.length - 1] ?? prev;
    pos -= x.length; // carry into the next chunk's index space
    return out;
  };
}

/// s16 LE bytes -> float32 [-1, 1].
export function pcm16ToFloat(buf: Uint8Array): Float32Array {
  const out = new Float32Array(buf.length / 2);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  for (let i = 0; i < out.length; i++) out[i] = view.getInt16(i * 2, true) / 32768;
  return out;
}
