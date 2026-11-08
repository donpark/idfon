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
16-conversation sample is CC-BY-4.0. The creators have confirmed that derived
annotations may be redistributed as long as no audio is included. **Resolution:
we publish annotated ranges, never the audio.** A label row names the
conversation and the clip window, so a reader who has the public sample re-cuts
the audio locally.

The publishable artifact is `docs/open-yap-turn-annotations/` — 1,716 ranges over
the 16 public conversations (8.92 h), ranges only, ~1 MB. It is the HF dataset
`donpark/open-yap-1k-turn-annotations`. The internal 994-row stratified sample
(`bench-results/openyap-v0-2026-11-07/`, drawn from 615 conversations of the full
corpus) stays internal; so does its clip set.

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

## The published release

`docs/open-yap-turn-annotations/` — 1,716 ranges over the 16 public conversations
(8.92 h), built by `scripts/openyap-publish.py` from the gated manifest. Ships as
`ranges.jsonl`, `manifest.csv`, `validation.json`, `SHA256SUMS`, a dataset card,
the source licence and a notice. No audio. The public 16 are the CC-BY-4.0 sample,
so the licensing is unambiguous; the full-corpus ranges remain internal.

## The internal v0 sample

`bench-results/openyap-v0-2026-11-07/` — 994 clips, 142 per stratum, drawn by
`scripts/openyap-v0.py`. Equal counts per stratum so the 69% overlap population
does not drown the rest: handoff_short, handoff_long, tail_short, tail_long,
overlap_short, overlap_long, backchannel. Ships as `ranges.jsonl` (the label
record, keyed to source ranges), `manifest.csv`, 994 clips (366 MB) and a
listening page with a turn-range rubric. No human has auditioned it yet. The rows
span 615 conversations of the full DUA corpus, so the sample is internal-only.

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
interruption — but recall is low.

**Per-clip, against a base rate.** "The nearest ENDPOINT is close" is trivially
true when a clip fires many events, so each rate is compared with the chance of
one uniform event in a 10 s window landing that close:

| kind | events/clip | within ±0.32 s | chance | enrichment |
| --- | ---: | ---: | ---: | ---: |
| handoff | 0.5 | 3/28 (11%) | 3% | **3.7×** |
| silent_tail | 0.6 | 4/16 (25%) | 3% | **8.0×** |
| overlap | 0.2 | 0/76 (0%) | 2% | 0× |

The silent-agent run (`--silent-agent`, LISTEN init, agent channel muted) does
**not** improve this: events/clip rises to 1.2–1.3, the hit rate stays at 11%
(handoff) and falls to 19% (silent_tail), and the chance level rises to 7–8%. So
enrichment drops to 1.6× and 2.4× — muting the agent channel makes the model
spray events rather than aim them. Silencing is not the fix; the next
paragraph shows the "mode confound" itself was misdiagnosed.

**The mode explanation was wrong, and the measurement says why.** The first read
was "ch1 is a second human who talks, so the model sits in SPEAK ~40% of the
lead". Measuring the lead directly contradicts it: in 20 handoff clips the
next speaker's channel sits 26–100 dB *below* the ender's, and of the 9 clips
reported as SPEAK-in-lead, **9 of 9** have that channel below −50 dB for the
whole lead — 7 of them with every frame below it. So no partner is talking.

The cause is the mode track's 1.92 s release latch (`RELEASE_HOPS = 6`): one
transient up to ~0.7 s *before* the clip's 1.2 s lead latches SPEAK across the
whole lead. "SPEAK in the lead" is therefore stale state, not partner speech.
Two consequences: the 40% figure says nothing about who was talking, and the
"LISTEN-only lead" subset above selects on latch luck rather than on partner
silence — so its 21%/56% should not be read as a clean LISTEN measurement.

Why ENDPOINT stays low is therefore still open. The candidates are the latch
above (an ENDPOINT gate that needs LISTEN, defeated by stale SPEAK), the
ENDPOINT debounce, or a genuine difference in what the model calls a turn end.

**Replay with the latch removed** (`--release-hops 1`, same 120 rows):

| kind | ENDPOINT ±0.32 s, latch | no latch | events/clip | SPEAK lead |
| --- | ---: | ---: | ---: | ---: |
| handoff | 3/28 (11%) | 4/28 (14%) | 0.5 → 0.8 | 39% → 7% |
| silent_tail | 4/16 (25%) | 6/16 (38%) | 0.6 → 1.1 | 42% → 10% |
| overlap | 0/76 (0%) | 0/76 (0%) | 0.2 → 0.5 | 43% → 13% |

The latch costs recall and buys no ENDPOINT precision — false ENDPOINTs on
overlaps stay at zero without it. So softening the latch is a net win for this
event (the BARGE/BACKCHANNEL precision it protects is a separate question). But
recall only reaches 14%/38%, so the latch was not the main limiter.

**The remaining explanation is a category mismatch.** At handoff marks the model
most often emits BACKCHANNEL, not ENDPOINT (10 of 13 landings with the latch
removed). The label asks "did the turn end"; the model answers "someone said a
short thing". That is the same conclusion the live-capture scoring reached by a
different route — the model's event vocabulary does not line up with
transcript-derived turn ends — and it means a smart-turn dataset should label
turn ends and let each model's event mapping be measured, rather than assume
ENDPOINT is the turn-end event.

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

- **Redistribution.** Settled: the creators confirmed annotated ranges publish,
  audio does not. The public release is ranges only; clips stay internal.
- **The public sample's kind mix.** 1,716 gated ranges over 16 conversations:
  overlap 1,159, handoff 301, silent_tail 255, backchannel 1. It is the gated
  population, not a balanced sample; the backchannel count is too low to train on.
- **The negative class.** A detector trained on positives only learns where the
  labels are. Negatives should be labelled at the same decision opportunities —
  `overlap` is the natural hard negative for "the turn ended".
- **Sample size for a public v0.** 23,287 handoffs is large; a smaller stratified,
  hand-auditable set may be the better release.
- **Channel semantics.** Either document that ch1 is a second human (so BARGE
  means "the other person talked over"), or map the barge event to the inverted
  channel order for that test.
