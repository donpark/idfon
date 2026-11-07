# Open Yap 1k turn ranges — the smart-turn label set

Status: **as-built v0.** A labelled-range dataset drawn from the Open Yap 1k
dual-channel corpus, built by transcript timestamps and gated on the audio's own
lead. The purpose is a public artefact developers can test or train a smart-turn
detector against, keyed to ranges of the original audio rather than shipped
clips.

Related: `voice-decision-model.md` (the turn layer's event spec and the Open Yap
threshold sweep), `tyger-models/README.md` (the annotation seam).

## Why this exists

The corpus's own metadata gives turn boundaries and per-conversation stats, but
not *events* — no "the caller took the floor here", "this was a silent tail",
"this was a barge". Those are what a smart-turn trainer needs. The corpus does
give word-level timestamps per speaker on separate channels, which is enough to
derive them.

## What the corpus gives

1,602 conversations, 1,000.2 h, 297 GB, 48 kHz mono per speaker, both channels
and both transcripts present for every conversation. Word-level `start`/`end`
per speaker. Per conversation: `dnsmos`, `signal_metrics`, `relationship`,
`turn_taking_gap_ms`, `turns_per_minute`, `speech_dominance`, duration.

Duration median 30.1 min (p10 4.4, p90 75.6, max 252). Relationships: friends
1,136, colleagues 173, romantic 157, family 136.

The full corpus is under a Data Use Agreement (not redistributable). The public
16-conversation sample is CC-BY-4.0. Whether derived *label files* count as "the
dataset" for redistribution is unresolved; until it is answered the labels ship
internally.

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
directions** — speaker A's turn end and speaker B's turn end are different
events.

## The channel convention

The product's model expects ch0 = the party whose turn end is being judged (the
"user") and ch1 = the party taking the floor (the "agent"). Open Yap's source
channels are just speaker_a and speaker_b, so the extractor **normalises**: for a
row seen from B's turn end, the files are swapped. `dir` records which direction
produced the row (`a2b` or `b2a`) so a consumer can invert it.

This matters: before normalisation half the rows had the ender on ch1, so a model
scored on them was judging the wrong speaker's turn end.

## Two quality gates

The first 32-clip audit found 48% of handoff clips started with the caller
already talking, so the clip did not show the event's premise. Two gates fix it.

**Transcript gate** (`lead_ender`/`lead_next` in `openyap-ranges.py`): the 1.2 s
before the mark must be at least half covered by the ender's words and at most a
tenth by the next speaker's. Keeps 53% of all ranges.

**Audio gate** (`openyap-audio-gate.py`): the transcript misses everything it
does not spell — laughs, breaths, throat clears, noise. In the first audited
clip the next speaker vocalised for 240 ms before the ender's last word and
`lead_next` was 0.0. So the gate also measures channel dominance per 80 ms frame
(6 dB): the ender must own at least half the lead and the next speaker at most a
tenth. Keeps 67% of the transcript-clean rows.

Both together keep 35% of all candidate ranges.

## Counts

| stage | rows |
| --- | ---: |
| candidate ranges | 457,509 |
| transcript-clean | 240,531 (53%) |
| transcript + audio clean | 161,432 (35%) |

Gated by kind: overlap 110,846 · silent_tail 26,892 · handoff 23,287 ·
backchannel 407. 1,602 conversations.

## Files and disk

Built under `bench-results/openyap-ranges-2026-11-07/` (gitignored):

- `ranges.jsonl` — every candidate range (457,509 rows).
- `manifest.jsonl` — transcript-clean (240,531 rows).
- `manifest_gated.jsonl` — transcript + audio clean (161,432 rows), the shipped set.
- `clips/batch_NNN/` — 6.0 s stereo 16 kHz WAVs. 242,934 files, ~90 GB, covering
  every transcript-clean row including the audio-dirty ones.
- `README.md` — the artefact's own readme.

The clip set is larger than the gated manifest because the audio gate runs after
extraction. Dropping the audio-dirty clips would reclaim ~31 GB.

Disk is the binding constraint: all 457,509 ranges would be ~176 GB. The build
therefore extracts only transcript-clean rows (46 GB more for the `b2a` half).

## Step 4: scoring the product's ears against the labels

`openyap-score.py` runs the turn layer over gated ranges. It re-decodes 8 s
before the turn end rather than reading the 1.2 s-lead clips, because the model's
window is 8 s: scored on a 1.2 s lead the model is cold and the result is not the
product's behaviour. Channels follow the clip convention.

The decision frame is the ender's last word end, 8 s into the window. An event
lands when it fires within a tolerance of that frame.

**120-clip sample** (`--kinds handoff,silent_tail,overlap`, seed 0). ENDPOINT is
the event that means "the user's turn ended":

| kind | n | ENDPOINT ±0.32 s | ENDPOINT ±0.64 s | LISTEN-only lead |
| --- | ---: | ---: | ---: | ---: |
| handoff | 28 | 3 (11%) | 4 (14%) | 3/14 (21%) |
| silent_tail | 16 | 4 (25%) | 6 (38%) | 5/9 (56%) |
| overlap | 76 | 0 (0%) | 0 (0%) | 0/33 (0%) |

Reading: the direction is right and clean — ENDPOINT never fires on an
interruption — but recall is low. The cause is the mode track, not the labels.
In a two-human clip, ch1 (the model's "agent" channel) is a person who talks, so
the model sits in SPEAK mode for ~40% of the decision lead. ENDPOINT only fires
in LISTEN mode, so those clips cannot produce it by construction. Restricting to
clips whose lead is LISTEN-only lifts silent_tail to 56% and handoff to 21%,
still with zero overlap fires.

The consequence for the dataset: the labels are valid, but scoring the product's
ears on a two-human corpus tests the wrong mode. Either gate the score on
LISTEN-mode frames, or map "agent" to the party who is silent at the decision —
and document that ch1 is a second human, so BARGE here means "the other person
talked over", the inverse of the product's meaning.

BARGE fires about 7 times per clip in every kind (7.8 handoff, 7.2 silent_tail,
7.1 overlap), which is the same confound seen from the other side.

Cost: ~10 s per clip single-process on MPS. Scoring all 23,287 gated handoffs is
~65 h; a batched path is needed before a full-corpus score.

## Rebuild

```bash
V=ports/tyger-student/.venv/bin/python
$V scripts/openyap-ranges.py --selfcheck
$V scripts/openyap-ranges.py \
  --data datasets/open-yap-1k_2026-11-07_flac_372fb0fd \
  --out bench-results/openyap-ranges-2026-11-07/ranges.jsonl \
  --events handoff,overlap,silent_tail,backchannel          # 16 s
$V scripts/openyap-ranges.py \
  --extract bench-results/openyap-ranges-2026-11-07/ranges.jsonl \
  --data datasets/open-yap-1k_2026-11-07_flac_372fb0fd \
  --out bench-results/openyap-ranges-2026-11-07/clips \
  --clean --workers 12 --batch 1000                          # 10 min, ~90 GB
$V scripts/openyap-audio-gate.py \
  --manifest bench-results/openyap-ranges-2026-11-07/manifest.jsonl \
  --clips bench-results/openyap-ranges-2026-11-07/clips \
  --out bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl   # 45 s
TYGER_BUNDLE=... $V scripts/openyap-score.py \
  --manifest bench-results/openyap-ranges-2026-11-07/manifest_gated.jsonl \
  --sample 90 --out /tmp/score90.jsonl
```

## Open questions

- **Redistribution.** Do derived label files count as "the dataset"? Decides
  publishable vs internal.
- **The negative class.** A detector trained on positives only learns where the
  labels are. Negatives should be labelled at the same decision opportunities —
  `overlap` is the natural hard negative for "the turn ended".
- **Sample size for a public v0.** 23,287 handoffs is large; a smaller stratified,
  hand-auditable set may be the better release.
- **Channel semantics.** Either document that ch1 is a second human (so BARGE
  means "the other person talked over"), or map the barge event to the inverted
  channel order for that test.
