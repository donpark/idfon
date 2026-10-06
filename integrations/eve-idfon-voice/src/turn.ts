// Turn heuristics shared by every voice agent: endpointing, silence trim,
// clause batching, envelope stripping, echo suppression. These are the TS
// counterparts of the Rust `idfon-voice` heuristics; keep them in sync.
//
// PCM is s16le mono at `RATE` unless noted.

import { RATE } from "./audio";

export type EndpointEvent = "speech-started" | "speech-ended";

const ENERGY_THRESHOLD = 300;
const ENDPOINT_QUIET_MS = 800;

function loud(pcm: Buffer, threshold: number): boolean {
  for (let i = 0; i + 1 < pcm.length; i += 2) {
    const sample = pcm.readInt16LE(i);
    if (sample > threshold || sample < -threshold) return true;
  }
  return false;
}

/// Energy endpointer: speech starts on a loud frame, ends after a quiet tail.
/// Mirrors `idfon-voice`'s `EnergyEndpointer` (`|s16| > 300`, 800 ms quiet).
export class EnergyEndpointer {
  #speaking = false;
  #quietFrames = 0;
  constructor(
    private readonly rate = RATE,
    private readonly threshold = ENERGY_THRESHOLD,
    private readonly quietMs = ENDPOINT_QUIET_MS,
  ) {}

  push(pcm: Buffer): EndpointEvent | null {
    if (pcm.length < 2) return null;
    if (loud(pcm, this.threshold)) {
      this.#quietFrames = 0;
      if (!this.#speaking) {
        this.#speaking = true;
        return "speech-started";
      }
      return null;
    }
    if (!this.#speaking) return null;
    this.#quietFrames += Math.floor(pcm.length / 2);
    if (this.#quietFrames >= (this.rate * this.quietMs) / 1000) {
      this.#speaking = false;
      this.#quietFrames = 0;
      return "speech-ended";
    }
    return null;
  }

  reset(): void {
    this.#speaking = false;
    this.#quietFrames = 0;
  }
}

/** Drop leading near-silence, keeping a short lead-in (no click). A live
 * model streams silence until its first audio token (TTFB), so without this a
 * reply clip opens with dead air. */
export function trimLeadingSilence(
  pcm: Buffer,
  { threshold = ENERGY_THRESHOLD, keepMs = 100, rate = RATE } = {},
): Buffer {
  let start = 0;
  while (start + 2 <= pcm.length) {
    const sample = pcm.readInt16LE(start);
    if (sample > threshold || sample < -threshold) break;
    start += 2;
  }
  const keep = Math.max(0, start - rate * 2 * (keepMs / 1000));
  return pcm.subarray(keep);
}

/** Drop trailing near-silence, keeping a short fade-out tail (no click). */
export function trimTrailingSilence(
  pcm: Buffer,
  { threshold = ENERGY_THRESHOLD, keepMs = 250, rate = RATE } = {},
): Buffer {
  let end = pcm.length;
  while (end >= 2) {
    const sample = pcm.readInt16LE(end - 2);
    if (sample > threshold || sample < -threshold) break;
    end -= 2;
  }
  const keep = Math.min(pcm.length, end + rate * 2 * (keepMs / 1000));
  return pcm.subarray(0, keep);
}

/** Emit whole clauses from streamed text; keep the trailing fragment. */
export class ClauseBatcher {
  #pending = "";

  push(text: string): string[] {
    this.#pending += text;
    const out: string[] = [];
    let index: number;
    while ((index = this.#pending.search(/[.!?\n]/)) >= 0) {
      const clause = this.#pending.slice(0, index + 1);
      this.#pending = this.#pending.slice(index + 1);
      if (clause.trim()) out.push(clause);
    }
    return out;
  }

  finish(): string | null {
    const text = this.#pending;
    this.#pending = "";
    return text.trim() ? text : null;
  }
}

/** Drop a trailing IDFON envelope block (a line ending in "/1") before speaking. */
export function stripEnvelopes(text: string): string {
  const lines = text.split("\n");
  const out: string[] = [];
  for (const line of lines) {
    if (/^IDFON-.*\/1$/.test(line.trim())) break;
    out.push(line);
  }
  return out.join("\n").trim();
}

function tokens(text: string): string[] {
  return text.toLowerCase().split(/\s+/).filter(Boolean);
}

/** Drop STT finals that just echo the text currently being spoken. */
export class EchoSuppressor {
  #spoken: string[] = [];

  /** Record the text being spoken (tokenized, contiguous-run matching). */
  setSpoken(text: string): void {
    this.#spoken = tokens(text);
  }

  isEcho(final: string): boolean {
    const candidate = tokens(final);
    if (candidate.length === 0) return false;
    const spoken = this.#spoken.join(" ");
    return spoken.includes(candidate.join(" "));
  }
}

const BACKCHANNELS = new Set([
  "mm-hmm",
  "mmhmm",
  "uh-huh",
  "uhhuh",
  "yeah",
  "yep",
  "okay",
  "ok",
  "right",
  "sure",
  "hmm",
]);

/** Short acknowledgements that should not cancel agent speech (F6). */
export function isBackchannel(text: string): boolean {
  const words = tokens(text);
  return words.length > 0 && words.length <= 2 && words.every((word) => BACKCHANNELS.has(word));
}

/** Sentence-ish minimum length below which a barge-in is ignored. */
export function isCancellable(text: string, minWords = 2): boolean {
  return tokens(text).length >= minWords;
}
