// Per-call observation record: one JSON object per call, appended as JSONL.
// The evidence base for voice style adaptation research — does friction
// (re-asks, repair, early hangups) concentrate where user speaking habits and
// agent behavior mismatch? Habit stats, behavior stats, raw friction events,
// and turns only: no classifiers, no models, no adaptation logic.

/** Reserved for RCS-style paralinguistic annotation strings (e.g.
 * `([emotion angry=0.81, neutral=0.12],[sarcasm value=0.04])`). Always null in
 * v1: annotation parsing/perception is deliberately not implemented, the slot
 * only exists so those strings can be carried later without a schema change. */
export interface Paralinguistics {
  emotion: string | null;
  sarcasm: string | null;
  delivery: string | null;
}

export type TurnRole = "user" | "agent";

/** One conversational turn. `started_ms`/`duration_ms` are call-relative
 * (call start = 0): user turns cover the captured utterance, agent turns cover
 * the reply delivery (TTS + posting), approximating the audible window. */
export interface TurnEntry {
  text: string;
  role: TurnRole;
  started_ms: number;
  duration_ms: number;
  how: Paralinguistics;
}

export type FrictionType = "reask" | "repair" | "barge_restart" | "early_hangup";

/** Raw friction evidence; `turn_index` points into `CallRecord.turns`. */
export interface FrictionEvent {
  type: FrictionType;
  turn_index: number;
  excerpt: string;
}

/** Nearest-rank percentiles over the call's turns. */
export interface Percentiles {
  p50: number;
  p90: number;
}

/** A backchannel-detector event at call-relative ms (src/bcd/decisions.ts). */
export interface BcdEvent {
  kind: "backchannel" | "floor_take";
  at_ms: number;
  p: number;
}

export interface BcdSummary {
  backchannels: number;
  floor_takes: number;
  events: BcdEvent[];
}

/** One turn's delay ledger, all call-relative ms (call start = 0). The gaps
 * between the caller's last voiced audio and the agent's first audible audio
 * are the UX waiting time; the endpointer and the model are where the loop
 * waits. Additive to `turns[]` — the same order, one entry per user turn. */
export interface TurnLatency {
  /** Index into `turns[]` of the user turn this ledger belongs to. */
  turn_index: number;
  /** The caller's last voiced frame: the utterance's end, not the quiet tail. */
  caller_stop_ms: number;
  /** The endpoint decision fired. */
  endpoint_ms: number;
  /** `caller_stop_ms` → `endpoint_ms`: the endpointer's own delay. */
  decision_ms: number;
  /** Which endpointer ended the turn. */
  endpoint_source: "tyger" | "energy";
  /** `endpoint_ms` → the turn starting its STT/agent work. */
  queue_ms: number;
  /** STT request → transcript. */
  stt_ms: number;
  /** Agent request → reply (the full round trip, bridge included). */
  reply_ms: number;
  /** The bridge's clock for the agent's generation alone; null when the
   *  bridge did not report it. `reply_ms - agent_ms` is bridge overhead. */
  agent_ms: number | null;
  /** TTS request start → the first PCM posted to the bridge. */
  tts_ttfb_ms: number | null;
  /** TTS delivery: first PCM → last PCM posted. */
  tts_ms: number;
  /** Bridge POST time inside TTS delivery. */
  play_ms: number;
  /** The caller's perceived wait: `caller_stop_ms` → first PCM posted. */
  heard_ms: number | null;
  /** Mean frame-loop push cost during the turn (the model's own time). */
  frame_ms: number;
}

/** Per-call latency summary: the raw ledger plus nearest-rank percentiles over
 * the turns that produced one. The percentiles are the UX question's numbers. */
export interface CallLatency {
  turns: TurnLatency[];
  decision_ms: Percentiles;
  queue_ms: Percentiles;
  stt_ms: Percentiles;
  reply_ms: Percentiles;
  agent_ms: Percentiles;
  tts_ttfb_ms: Percentiles;
  heard_ms: Percentiles;
  /** Mean frame-loop push cost across the call: the model's own time. */
  frame_ms: number;
  /** Turns ended by each endpointer. */
  endpoint_sources: { tyger: number; energy: number };
}

export interface CallRecord {
  schema: "eve-idfon-voice.call-observe/1";
  call_id: string;
  started_at: string;
  duration_ms: number;
  turn_count: number;
  user: {
    turn_duration_ms: Percentiles;
    words_per_turn_p50: number;
    /** User turns starting during an agent delivery window / user turns. */
    interjection_rate: number;
    backchannels: number;
    repairs: number;
    /** backchannels / (backchannels + repairs); null when neither occur. */
    backchannel_ratio: number | null;
  };
  agent: {
    reply_duration_ms: Percentiles;
    /** Median first-sentence length (chars) across agent replies. */
    preamble_chars_p50: number;
  };
  friction: FrictionEvent[];
  /** Backchannel-detector summary (src/bcd/), null when the detector was off. */
  bcd: BcdSummary | null;
  /** Per-turn delay ledger: where the call's waiting time goes. */
  latency: CallLatency;
  turns: TurnEntry[];
}
