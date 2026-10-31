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
  turns: TurnEntry[];
}
