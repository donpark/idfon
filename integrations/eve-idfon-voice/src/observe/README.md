# src/observe — per-call observation record

One JSON object per call (JSONL): user habit stats, agent behavior stats, raw
friction events, and per-turn entries with a reserved paralinguistic slot. The
evidence-gathering step for voice style adaptation research — does friction
(re-asks, repair, early hangups) concentrate where user speaking habits and
agent behavior mismatch? No classifiers, no models, no adaptation logic.

- `schema.ts` — the record types (`eve-idfon-voice.call-observe/1`)
- `collector.ts` — `CallRecorder`: turns + playback-truncation marks, `build()`
  derives the stats and joins the friction events
- `emitter.ts` — the JSONL sink

## Schema: `eve-idfon-voice.call-observe/1`

```json
{
  "schema": "eve-idfon-voice.call-observe/1",
  "call_id": "call-m2x9k1",
  "started_at": "2026-10-31T14:02:11.203Z",
  "duration_ms": 184320,
  "turn_count": 7,
  "user": {
    "turn_duration_ms": { "p50": 2100, "p90": 6400 },
    "words_per_turn_p50": 6,
    "interjection_rate": 0.33,
    "backchannels": 2,
    "repairs": 1,
    "backchannel_ratio": 0.6667
  },
  "agent": {
    "reply_duration_ms": { "p50": 4200, "p90": 9100 },
    "preamble_chars_p50": 42
  },
  "friction": [
    { "type": "barge_restart", "turn_index": 4, "excerpt": "wait, what do you mean" },
    { "type": "repair", "turn_index": 4, "excerpt": "wait, what do you mean" },
    { "type": "early_hangup", "turn_index": 6, "excerpt": "" }
  ],
  "bcd": { "backchannels": 1, "floor_takes": 0, "events": [ { "kind": "backchannel", "at_ms": 52100, "p": 0.83 } ] },
  "latency": {
    "turns": [
      {
        "turn_index": 1,
        "caller_stop_ms": 12500,
        "endpoint_ms": 13020,
        "decision_ms": 520,
        "endpoint_source": "tyger",
        "queue_ms": 12,
        "stt_ms": 280,
        "reply_ms": 1450,
        "agent_ms": 1120,
        "tts_ttfb_ms": 190,
        "tts_ms": 980,
        "play_ms": 70,
        "heard_ms": 2452,
        "frame_ms": 22
      }
    ],
    "decision_ms": { "p50": 520, "p90": 520 },
    "queue_ms": { "p50": 12, "p90": 12 },
    "stt_ms": { "p50": 280, "p90": 280 },
    "reply_ms": { "p50": 1450, "p90": 1450 },
    "agent_ms": { "p50": 1120, "p90": 1120 },
    "tts_ttfb_ms": { "p50": 190, "p90": 190 },
    "heard_ms": { "p50": 2452, "p90": 2452 },
    "frame_ms": 22,
    "endpoint_sources": { "tyger": 1, "energy": 0 }
  },
  "turns": [
    {
      "text": "mm-hmm",
      "role": "user",
      "started_ms": 12500,
      "duration_ms": 400,
      "how": { "emotion": null, "sarcasm": null, "delivery": null }
    }
  ]
}
```

Field notes (heuristics are deliberately crude — raw evidence, not judgments):

- `started_ms` / `duration_ms` are call-relative (call start = 0). User turns
  cover the captured utterance; agent turns cover the reply delivery
  (TTS + posting), approximating the audible window.
- `user.turn_duration_ms` / `agent.reply_duration_ms`: nearest-rank percentiles.
- `user.interjection_rate`: user turns starting during an agent delivery
  window / user turns.
- `user.backchannels` / `user.repairs`: simple text heuristics — backchannel =
  a turn of ≤2 acknowledgement words (`mm-hmm/yeah/right/ok/…`, the word set
  mirrored from `src/turn.ts`, kept in sync by hand), repair = the turn contains
  `wait` / `what do you mean` / `huh` / `sorry?`.
- `user.backchannel_ratio` = backchannels / (backchannels + repairs), null when
  neither occur.
- `agent.preamble_chars_p50`: median first-sentence length (chars) of the
  spoken reply text. "Chars before the first answer-bearing sentence" is not
  determinable cheaply, so the whole first sentence is the v1 stand-in.
- `friction[]` raw events (`turn_index` points into `turns[]`):
  - `reask` — a user turn whose token Jaccard vs a user turn 2–4 turn indices
    earlier is ≥ 0.6 (re-ask/rephrase); excerpt is the later turn.
  - `repair` — a user turn matching the repair heuristic above.
  - `barge_restart` — a playback truncation joined with the following user
    turn. `CallRecorder.recordPlaybackTruncated` is the seam; live-relay marks
    it on the tyger `barge` decision, the TS-side analog of the Rust
    `TurnBridge::record_playback_truncated`.
  - `early_hangup` — call ended with < 4 turns or < 30 s.
- `bcd` — backchannel-detector events (src/bcd/) at call-relative ms: counts +
  raw events. **Null when the detector was off** (`IDFON_BCD=off` or no model
  bundle). Shadow only: recorded, never acted on.
- `latency` — the per-turn delay ledger: where the call's waiting time goes.
  One entry per user turn that reached the reply path, in `turns[]` order.
  - `caller_stop_ms` — the caller's last voiced frame: the utterance's end, not
    the quiet tail's end.
  - `endpoint_ms` — the endpoint decision fired. `decision_ms` is the gap: the
    endpointer's own delay (the tyger head's time, or the energy path's 800 ms
    quiet tail).
  - `endpoint_source` — `tyger` (the head ended the turn) or `energy` (the
    fail-open fallback did). The split is the first question when a call feels
    slow: the wrong endpointer explains a lot of waiting.
  - `queue_ms` — `endpoint_ms` → the turn starting its STT/agent work.
  - `stt_ms`, `reply_ms` — the STT and wrapped-agent requests. `reply_ms` is
    the full round trip; `agent_ms` is the bridge's clock for the agent's
    generation alone. `reply_ms - agent_ms` is the bridge's own overhead — the
    split that tells you whether the wait is the model or the plumbing. Null
    when the bridge did not report it.
  - `tts_ttfb_ms` — TTS request start → the first PCM posted to the bridge;
    null when TTS produced no audio. `tts_ms` is the whole delivery window,
    `play_ms` the bridge POST time inside it.
  - `heard_ms` — the caller's perceived wait: `caller_stop_ms` → first PCM
    posted. Null when no audio was produced.
  - `frame_ms` — the mean frame-loop push cost during the turn: the decision
    model's own time. A push slower than the frame's audio duration means the
    loop is falling behind real time.
  - The top-level percentiles are nearest-rank over the turns; empty sets
    report 0.
- `turns[].how` — **reserved paralinguistic slot**, always nulls in v1. Later
  it carries RCS-style annotation strings (e.g.
  `([emotion angry=0.81, neutral=0.12],[sarcasm value=0.04])`); parsing and
  perception are deliberately not implemented.

## Wiring

`live-relay.mjs` feeds a `CallRecorder` as turns are heard and replies played,
and appends one JSONL line at call teardown (the `/live/stream` SSE ending).
Fully passive: the sink's failure is logged and dropped. Default sink:
`~/.idfon/observe/calls.jsonl`; `IDFON_CALL_RECORDS` overrides the path or
disables with `off`.
