# Voice prompt lab

`scripts/voice-prompt-lab.sh` iterates voice-agent prompts headlessly. It
brings up the real stack in a throwaway instance — a temp daemon, the holder
(with a chosen live config), the eve agent, and the bridge — sends scripted
caller turns, and prints the replies. No iPhone, no call, no audio.

**Use it** to change a prompt and see the effect in seconds:

```
scripts/voice-prompt-lab.sh --turn "what is the capital of France?"
scripts/voice-prompt-lab.sh --turns turns.jsonl --score
scripts/voice-prompt-lab.sh --variants prompts/voices --turns turns.jsonl
```

- `--config FILE` — a live config to serve (repeatable). The holder folds its
  `instructions` into each turn (see `docs/voice-agent.md`).
- `--variants DIR` — run every `*.json` in `DIR` and print a ranked table.
- `--turns FILE` — one turn per line: plain text, or a JSON object
  `{"text": "...", "expect": "...", "forbid": ["..."]}`. Keep a corpus with the
  agent it tests (`agents/<agent>/turns.jsonl`); `expect`/`forbid` are the whole
  specification a scorer or optimizer sees.
- `--json-out FILE` — append one JSON object per scored turn (`config`, `text`,
  `reply`, `expect`, `forbid`, `score`) for a tool to consume.

## Scoring

A turn with `expect`/`forbid` is scored: it passes when the reply contains
`expect` and contains none of `forbid`. A config prints `passed/scored` and a
mean; several configs print a ranked table. Unscored turns are printed but do
not affect the mean.

The score is a deterministic rubric, not a model judge — reproducible and
free. A model judge (0–1 per turn against a rubric) can be added as another
scoring mode when rubrics are not enough.

## Limits

- The caller is text, so ASR/echo effects do not appear. Use a real call for
  those; this lab isolates the holder → agent prompt surface.
- It needs `AI_GATEWAY_API_KEY` for the agent's model.
- One full stack per config; a run is seconds, not milliseconds.

## GEPA

`scripts/voice-gepa.sh` optimizes a prompt with this lab as its objective. Each
generation rewrites the current best prompt from the turns it failed
(`scripts/voice-gepa-mutate.py`, an LLM call through the AI gateway), scores
every rewrite over a labelled corpus, keeps the best, and repeats:

```
scripts/voice-gepa.sh                                   # 2 generations x 3 variants
scripts/voice-gepa.sh --generations 3 --variants 4 --corpus agents/llm/turns.jsonl
scripts/voice-gepa.sh --selftest                        # offline: fake lab + mutator
```

- The seed is scored first, so a run always reports the baseline it started from.
- One lab run per generation (all variants in one directory), then a ranked
  table; a rewrite only becomes "best" if it beats the incumbent.
- The winner is written to `agents/<agent>/live.optimized.json` — apply it by
  hand; a run never edits the seed's own config.
- `--selftest` runs the loop against a fake lab and mutator, so the wiring
  (feedback, ranking, winner) is tested with no key, no network and no spend.
  It caught a real bug: the seed was scored from one path and fed back as
  another, so the mutator was handed no failures at all.

**The corpus is the objective, not the goal.** Optimizing against 11 turns
mostly written from rules overfits those turns; a rewrite that fixes them can
still be worse on a real call. Grow the corpus from real calls (`#44`) — the
lab prints each turn's reply, so a failure is easy to promote into a labelled
line — and keep expectations on behaviour, not on wording.

Measured once (google/gemini-3.8-flash, 11 turns): seed 0.818 → 1.000 after two
generations, the winner being a rewrite that stopped naming the model and the
speech stack and dropped the canned "How can I help you today?" greeting. The
scorer itself was fixed in the same pass: the last `forbid` entry of every turn
had been silently untested, because a list built with `$(...)` has no trailing
newline and `while read` skips a final line without one.
