// Builds a CallRecord (src/observe/schema.ts) from raw turns and playback-
// truncation marks. Pure: every input is call-relative ms, `build()` derives
// the habit stats and joins the raw friction events. The Rust
// `TurnBridge::record_playback_truncated` is the daemon-side analog of
// `recordPlaybackTruncated`.

import type { CallRecord, FrictionEvent, Percentiles, TurnEntry, TurnRole } from "./schema.ts";

/** Early hangup: the call ended below either bound. */
export const EARLY_HANGUP_TURNS = 4;
export const EARLY_HANGUP_MS = 30_000;

const REASK_MIN_SIMILARITY = 0.6;
const REASK_MIN_GAP = 2; // "~3 turns apart": one to two exchanges earlier
const REASK_MAX_GAP = 4;
const EXCERPT_CHARS = 160;

const HOW_NULLS = { emotion: null, sarcasm: null, delivery: null };

// Mirrors src/turn.ts's isBackchannel word set (kept in sync by hand: turn.ts
// is not loadable under plain-Node type stripping, which is how tests and
// live-relay.mjs run). Backchannels are short acknowledgement-only turns.
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

// Repair initiators: crude substring/word matches on the turn text.
const REPAIR_RE = /\bwait\b|what do you mean|\bhuh\b|\bsorry\?/i;

export interface TurnInput {
  text: string;
  role: TurnRole;
  started_ms: number;
  duration_ms: number;
}

export class CallRecorder {
  readonly callId: string;
  readonly startedAt: Date;
  #turns: TurnEntry[] = [];
  #truncations: number[] = [];

  constructor(callId: string, startedAt: Date = new Date()) {
    this.callId = callId;
    this.startedAt = startedAt;
  }

  addTurn(input: TurnInput): void {
    this.#turns.push({ ...input, how: { ...HOW_NULLS } });
  }

  /** Playback was cut short by a barge-in at `atMs` (call-relative). */
  recordPlaybackTruncated(atMs: number): void {
    this.#truncations.push(atMs);
  }

  build(endedAt: Date = new Date()): CallRecord {
    const turns = this.#turns.map((t) => ({ ...t }));
    const userTurns = turns.filter((t) => t.role === "user");
    const agentTurns = turns.filter((t) => t.role === "agent");
    const backchannels = userTurns.filter((t) => isBackchannel(t.text)).length;
    const repairs = userTurns.filter((t) => REPAIR_RE.test(t.text)).length;
    return {
      schema: "eve-idfon-voice.call-observe/1",
      call_id: this.callId,
      started_at: this.startedAt.toISOString(),
      duration_ms: endedAt.getTime() - this.startedAt.getTime(),
      turn_count: turns.length,
      user: {
        turn_duration_ms: percentiles(userTurns.map((t) => t.duration_ms)),
        words_per_turn_p50: percentile(userTurns.map((t) => tokens(t.text).length), 0.5),
        interjection_rate: userTurns.length === 0 ? 0 :
          userTurns.filter((t) => agentTurns.some((a) =>
            t.started_ms >= a.started_ms && t.started_ms <= a.started_ms + a.duration_ms)).length / userTurns.length,
        backchannels,
        repairs,
        backchannel_ratio: backchannels + repairs === 0 ? null : backchannels / (backchannels + repairs),
      },
      agent: {
        reply_duration_ms: percentiles(agentTurns.map((t) => t.duration_ms)),
        preamble_chars_p50: percentile(agentTurns.map((t) => firstSentenceLength(t.text)), 0.5),
      },
      friction: this.#friction(turns, endedAt.getTime() - this.startedAt.getTime()),
      turns,
    };
  }

  #friction(turns: TurnEntry[], durationMs: number): FrictionEvent[] {
    const out: FrictionEvent[] = [];
    // Repair initiators.
    for (let i = 0; i < turns.length; i++) {
      if (turns[i].role === "user" && REPAIR_RE.test(turns[i].text)) {
        out.push({ type: "repair", turn_index: i, excerpt: excerpt(turns[i].text) });
      }
    }
    // Re-asks/rephrases: a user turn close in wording to a user turn ~3 turns
    // earlier (token Jaccard over the full turn list's indices).
    const userIndexed = turns.flatMap((t, i) => (t.role === "user" ? [[t, i] as const] : []));
    const reasked = new Set<number>();
    for (let a = 0; a < userIndexed.length; a++) {
      for (let b = a + 1; b < userIndexed.length; b++) {
        const gap = userIndexed[b][1] - userIndexed[a][1];
        if (gap < REASK_MIN_GAP) continue;
        if (gap > REASK_MAX_GAP) break;
        if (reasked.has(userIndexed[b][1])) continue;
        if (similarity(userIndexed[a][0].text, userIndexed[b][0].text) >= REASK_MIN_SIMILARITY) {
          reasked.add(userIndexed[b][1]);
          out.push({ type: "reask", turn_index: userIndexed[b][1], excerpt: excerpt(userIndexed[b][0].text) });
          break; // one earlier twin per turn
        }
      }
    }
    // Barge-in-then-restart: join each playback truncation with the following
    // user turn (the restart).
    const joined = new Set<number>();
    for (const at of this.#truncations) {
      const idx = turns.findIndex((t, i) => t.role === "user" && t.started_ms >= at && !joined.has(i));
      if (idx >= 0) {
        joined.add(idx);
        out.push({ type: "barge_restart", turn_index: idx, excerpt: excerpt(turns[idx].text) });
      }
    }
    if (turns.length < EARLY_HANGUP_TURNS || durationMs < EARLY_HANGUP_MS) {
      out.push({ type: "early_hangup", turn_index: Math.max(0, turns.length - 1), excerpt: "" });
    }
    return out.sort((x, y) => x.turn_index - y.turn_index || x.type.localeCompare(y.type));
  }
}

function tokens(text: string): string[] {
  return text.toLowerCase().split(/\s+/).filter(Boolean);
}

function isBackchannel(text: string): boolean {
  const words = tokens(text);
  return words.length > 0 && words.length <= 2 && words.every((word) => BACKCHANNELS.has(word));
}

function similarity(a: string, b: string): number {
  const sa = new Set(tokens(a));
  const sb = new Set(tokens(b));
  let shared = 0;
  for (const t of sa) if (sb.has(t)) shared++;
  return shared / (sa.size + sb.size - shared || 1);
}

function excerpt(text: string): string {
  const t = text.trim();
  return t.length > EXCERPT_CHARS ? t.slice(0, EXCERPT_CHARS - 1) + "…" : t;
}

/** Preamble length v1 = the whole first sentence: "answer-bearing sentence"
 * detection is not determinable cheaply, the first sentence is the stand-in. */
function firstSentenceLength(text: string): number {
  const trimmed = text.trim();
  return (/^[^.!?]*[.!?]?/.exec(trimmed)?.[0] ?? trimmed).trim().length;
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((x, y) => x - y);
  return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
}

function percentiles(values: number[]): Percentiles {
  return { p50: percentile(values, 0.5), p90: percentile(values, 0.9) };
}
