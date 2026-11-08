---
license: cc-by-4.0
language:
- en
task_categories:
- audio-classification
tags:
- turn-taking
- endpoint-detection
- smart-turn
- barge-in
- backchannel
- full-duplex
- conversation
- audio
size_categories:
- 1K<n<10K
---

# Open Yap 1k turn ranges

Turn-range annotations over the 16 public Open Yap 1k conversations — 8.92 h of
dual-channel conversation, released by The Agentic Data Company under CC-BY-4.0.
This dataset adds what the source does not have: labelled turn events, keyed to
ranges of the original audio. **No audio ships.**

It complements the source rather than replacing it. The source gives word-level
timestamps per speaker on separate channels; this dataset derives the turn
boundaries and events from those timestamps and gates them on the audio's own
channel dominance.

## Read this first

**This is an evaluation set, not a training set.** The labels are
transcript-derived and gated on the audio. A detector trained on them learns the
label's coverage, not turn-taking; the labels are valid positives and noisy
negatives. Use them to score a detector, not to fit one blindly.

**The public 16 are imbalanced.** 1,159 of the 1,716 rows are `overlap` (67%),
so the set is strongest as a barge-in / hard-negative benchmark. It contains
exactly **1 `backchannel` row** — too few to train or evaluate backchannel
detection. The full gated set (161,432 ranges) has 407 backchannels; use that if
you need them.

## What is here

| File | Rows | What it is |
| --- | ---: | --- |
| `ranges.jsonl` | 1,716 | one label record per decision opportunity |
| `manifest.csv` | 1,716 | the same rows flattened |
| `validation.json` | — | row/conversation/kind counts |
| `SHA256SUMS` | — | checksums of the two data files |
| `data/turn-annotations.jsonl` | 14,992 | the v0.1 pilot slice's per-frame records (see Prior artifact) |
| `manifest.json` | — | the v0.1 pilot slice's provenance |
| `human-audit-openyap.csv` | 75 | the v0.1 pilot slice's human audit |

Every row names the source conversation and a 6 s clip window. A reader with the
public audio re-cuts the same range locally; the audio never leaves the source.

## Why this dataset exists

A smart-turn detector — or an ear, a mouth, or a fusion of small models — needs to
know *where the floor changed* and *what kind of change it was*. The source has
the words and the timestamps but not the events. This dataset supplies the
events as ranges, so the consumer can train or evaluate against the same anchor
regardless of which model family it uses.

The schema is designed **our-needs-first**: the core is the decision frame our
voice stack needs, and the annotation fields are the observable facts a consumer
maps to its own decision vocabulary. It does not assume the Tyger event set, a
particular endpoint model, or a particular response policy. A model that stays on
the current turn-decision course, or tacks to an ear-only, mouth-only, or fused
design, reads the same rows.

## Schema

Core fields — the turn range and the decision frame:

| field | type | meaning |
| --- | --- | --- |
| `sample_id` | string | `conversation_id:kind:mark` — stable row key |
| `conversation_id` | string | Open Yap 1k conversation directory |
| `kind` | enum | `handoff`, `silent_tail`, `overlap`, `backchannel` |
| `dir` | enum | `a2b` or `b2a` — which speaker ends the turn |
| `turn_start`, `turn_end` | seconds | the ending speaker's turn |
| `mark` | seconds | the decision frame (the ender's last word end, or the interruption) |
| `gap_ms` | ms | ender's last word end → next speaker's first word start |
| `next_ms` | ms | the mark → the next speaker's first word start |
| `clip_start`, `clip_end` | seconds | the 6 s window to re-cut |
| `mark_s` | seconds | the mark's offset in that window (≤1.2) |

Quality fields — what the clip actually shows:

| field | meaning |
| --- | --- |
| `lead_ender`, `lead_next` | fraction of the 1.2 s lead covered by each speaker's words |
| `lead_clean` | the transcript gate: the ender owns the lead |
| `audio_ender_dom`, `audio_next_dom` | fraction of 80 ms frames where each channel dominates by 6 dB |
| `audio_clean` | the audio gate: the ender owns the lead in the audio too |

Context fields:

| field | meaning |
| --- | --- |
| `duration_s` | the source conversation's duration |
| `turns_per_minute` | the source conversation's metadata |
| `relationship` | the source conversation's metadata |

### Mapping to our needs

The core row is the ground truth; each consumer maps it to its own vocabulary.
For our turn-decision layer, the reading at the mark is:

| kind | what our decision layer should read |
| --- | --- |
| `handoff` | the caller's turn ended and the floor changed hands — respond or yield |
| `silent_tail` | the caller's turn ended and nobody spoke — the floor is open |
| `overlap` | the caller's turn did not end — listen, or hold and yield |
| `backchannel` | the caller acknowledged without claiming the floor — listen or backchannel |

An ear-only consumer reads `lead_*` and `audio_*` for the transcript/audio state
at the mark. A mouth-only consumer reads `mark` and `gap_ms` for when the floor
opened. A fused consumer joins its per-model decisions at the same `sample_id`.
None of them has to adopt the Tyger event set or the product's floor states.

### Extension fields (reserved, not populated in v0)

The core row is model-agnostic. These blocks are the seams a consumer fills when
it needs them; they are documented here so the schema does not have to change
when the product's model family does.

| block | serves | fields |
| --- | --- | --- |
| `decision` | the turn-decision layer | `floor` (`listen`/`hold`/`speak`/`backchannel`), `respond` |
| `ear` | ASR / ear models | transcript coverage, last-word confidence, channel |
| `mouth` | TTS / mouth models | first-audio time, overlap, response text |
| `fusion` | fused small models | per-model decisions at the same `mark` |

The invariant is `sample_id` and `mark`: every extension attaches to the same
decision frame, so a fused model can join blocks without re-deriving time.

## Event definitions

A **turn** is a maximal run of one speaker's words with no gap over 300 ms. The
corpus's p90 word gap is 160 ms and p95 is 640 ms, so 300 ms splits 7.7% of word
pairs — a boundary the transcripts already imply.

At each turn end, the next speaker's start decides the event:

| kind | condition | what it means |
| --- | --- | --- |
| `handoff` | next starts 0–320 ms after the turn ends | the turn ended and the floor changed hands |
| `silent_tail` | next starts 320–1200 ms after | the turn ended and nobody spoke |
| `overlap` | next starts inside the turn | the next speaker barged in |
| `backchannel` | short next turn (< 300 ms) inside the turn | an acknowledgement, not a floor claim |
| `long_pause` | next starts over 1200 ms after | not an event; the outer edge of the negatives |

Every turn end is a decision opportunity, so each moment is emitted in **both
directions** — speaker A's turn end and speaker B's turn end are different events.

## Channel convention

ch0 = the party whose turn end is being judged (the "user"); ch1 = the party
taking the floor (the "agent"). The source channels are `speaker_a`/`speaker_b`,
so the extractor normalises: for a row seen from B's turn end, the files are
swapped. `dir` records which direction produced the row (`a2b` or `b2a`) so a
consumer can invert it. Before normalisation half the rows had the ender on ch1,
so a model scored on them was judging the wrong speaker's turn end.

## How to re-cut the audio

The source audio is public and CC-BY-4.0. Download the sample, extract it, and
cut the ranges:

```bash
hf download TheAgenticDataCompany/open-yap-1k open-yap-1k-sample.tar --local-dir openyap
tar -xf openyap/open-yap-1k-sample.tar -C openyap/data

python scripts/openyap-ranges.py --extract ranges.jsonl \
  --data openyap/data --out clips --clip-s 6
```

`clip_start`/`clip_end` name the window; `mark_s` is the decision frame's offset
in it. The extractor swaps channels for `b2a` rows, so the ender is always ch0.

## Licensing and attribution

The source audio and transcripts are **CC-BY-4.0**, © The Agentic Data Company.
These annotations are derived from that material and are released **CC-BY-4.0**
with the same attribution. **No audio is included or redistributed here.**

The annotations are ours: the event derivation, the two quality gates and the
channel normalisation. If you use this dataset, cite the source and this set
(see `NOTICE.md`).

## Prior artifact (v0.1 pilot slice)

The repo also holds an earlier artifact: 14,992 per-frame `IDFON-VOICE-DECISION/1`
records over 20 minutes of 4 public conversations (`data/turn-annotations.jsonl`),
with `manifest.json` and a 75-item `human-audit-openyap.csv`. Those are Tyger
**teacher pseudo-labels**, not human ground truth — do not report agreement with
them as accuracy. They are for distillation and schema prototyping. Its README
is in the repo's git history (`0098b802`).

The turn ranges above are the human-auditable artifact; the pilot is the
per-frame teacher artifact. They are complementary, not duplicates.

## Composition

| kind | rows |
| --- | ---: |
| overlap | 1,159 |
| handoff | 301 |
| silent_tail | 255 |
| backchannel | 1 |

16 conversations, 8.92 h. The kind mix is the gated population of the public
sample, not a balanced sample: overlap dominates because two-human conversation
is mostly one person stepping on the other's end. `backchannel` is rare in this
sample — do not read the mix as the population's.

## Caveats

- **No human has auditioned this set.** The labels are transcript-derived plus an
  audio dominance gate. A listening pass is the next quality step.
- **The labels are ranges, not verdicts.** A `handoff` marks where a turn ended
  and someone else began, not whether the end was a good stopping point. That
  judgement is the model's, and measuring it is the point of the set.
- **ch1 is a second human.** In the product's terms ch1 is the "agent" channel,
  but in this source it is another person. A `barge` here means "the other person
  talked over", the inverse of the product's meaning. The channel normalisation
  keeps the ender on ch0; a consumer that maps ch1 to an agent must invert the
  barge semantics.
- **The audio gate is a 6 dB, 80 ms frame test**, not a VAD. It catches the laughs
  and breaths the transcript misses, but it does not prove the clip is clean.

## Citation

```bibtex
@misc{idfon_openyap_turn_ranges_2026,
  title  = {Open Yap 1k turn ranges},
  author = {Park, Don},
  year   = {2026},
  note   = {Turn-range annotations over the CC-BY-4.0 public sample of Open Yap 1k},
  url    = {https://huggingface.co/datasets/donpark/open-yap-1k-turn-annotations}
}
```

Source: [The Agentic Data Company, Open Yap 1k](https://theagenticdatacompany.com/open-yap-1k).
