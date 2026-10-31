# src/bcd — Pipecat backchannel detector (shadow mode)

Streaming ONNX backchannel/floor-take detector from
[pipecat-ai/backchannel-detector](https://huggingface.co/pipecat-ai/backchannel-detector)
(BSD-2), running in-process via onnxruntime-node. **Shadow/observation only: no
live path consumes this module.** It logs what the detector *would* have decided
on call audio (the `src/tyger/shadow.ts` swap-over convention) so its calls can
be diffed against real turn decisions before anything trusts it.

- `bundle.ts` — where the model lives on disk + a model.json/contract check
- `engine.ts` — `BcdEngine`: 40 ms chunks in, per-frame probs out, state threaded
- `decisions.ts` — `BcdDecisions`: per-frame probs -> backchannel / floor_take / none
- `shadow.ts` — `runShadow()`: live call audio -> JSONL decision log

## Model bundle

Resolution: `IDFON_BCD_BUNDLE` (a bundle dir), else `~/.idfon/models/bcd`.
Files (`backchannel-int8.onnx` preferred, `backchannel-fp32.onnx` fallback):

```sh
mkdir -p ~/.idfon/models/bcd && cd ~/.idfon/models/bcd
curl -LO https://huggingface.co/pipecat-ai/backchannel-detector/resolve/main/backchannel-int8.onnx
curl -LO https://huggingface.co/pipecat-ai/backchannel-detector/resolve/main/model.json
```

## Input contract (verified against the graph and model.json)

One `engine.chunk(pcm, botState)` call per 40 ms chunk; outputs per 20 ms frame
(2 per chunk).

| Feed | Shape | |
|---|---|---|
| `chunk` | `[1, 640]` | 16 kHz mono float32 in [-1, 1], user mic after echo cancellation |
| `bot_state` | `[1, 2, 8]` | per frame: bot speaking (0/1); seconds since bot onset, since the bot's last ≥200 ms pause, and since bot stop (each clipped to 5 s, ÷5); filler playing (0/1); 3 zeros — build rows with `botStateRow()` |
| `audio_cache` `[1,240]`, `stem_cache` `[1,80,4]`, `block0_cache` `[1,128,4]`, `block1_cache` `[1,128,8]`, `block2_cache` `[1,128,16]`, `block3_cache` `[1,128,32]`, `gru_state` `[2,1,192]` | | zeros at start; the engine feeds each `*_out` back automatically |

## Output contract

| Output | Shape | |
|---|---|---|
| `intent` | `[1, 2, 5]` | softmax over (continuer, assessment, negative, floor_take, non_speech) |
| `vad` | `[1, 2]` | user voice activity (auxiliary) |
| `vap` | `[1, 2, 8]` | user then bot activity 0–0.2 / 0.2–0.6 / 0.6–1.2 / 1.2–2.0 s ahead (auxiliary) |

p(backchannel) = continuer + assessment; p(floor) = negative + floor_take.

## Thresholds (`BcdThresholds`, all configurable)

Reference values from the model card ("Results"):

- **floor 0.7** — p(floor) crossing fires `floor_take` at once, once per
  crossing (re-arms below the threshold).
- **backchannel 0.7** — p(backchannel) crossing while the user speaks (aux
  `vad` ≥ 0.5) arms a pending call; it fires `backchannel` only once the user
  stops. **1.2 s backstop**: if the user has not stopped by then, the pending
  call is dropped (never fired late).
- A `floor_take` cancels a pending backchannel (the user is taking the floor).

## Running the shadow logger

```sh
node src/bcd/shadow.ts [bridge-url] [decision-log.jsonl]
# defaults: http://127.0.0.1:59861  ->  /tmp/bcd-shadow.jsonl
```

Reads the bridge's `GET /live/stream` (caller audio, 24 kHz s16, resampled to
16 kHz) and appends one JSON line per event: `{ts, kind, frame, p,
pBackchannel, pFloor, vad}` where `kind` is `backchannel` or `floor_take`
(`none` frames are not logged). Sits alongside the tyger shadow log — run both
against the same call and diff the decisions.

Shortcuts (same as `src/tyger/shadow.ts`): no TTS PCM seam at the bridge, so
`bot_state` is the constant "bot long silent" row and backchannel-vs-floor is
judged on user audio alone. Log both `kind`s and compare before trusting.

## CAVEATS

- **English only.**
- **Trained on human-to-human conversation, not human-to-bot.** People talk to
  voice agents differently; expect distribution shift.
- **The training echo is synthetic** (partner channel mixed back in), not real
  echo-cancellation residue. Real Opus decode + AEC residue is unverified.
- **Shadow-test before trusting.** This module only logs; make it authoritative
  only after the decision log has been diffed against real calls.
