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
  `{"text": "...", "expect": "...", "forbid": ["..."]}`.

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

This is the *runner* a GEPA/RL loop needs, not an optimizer. To optimize
prompts automatically, add a scorer and a variant generator on top, using the
turn traces (#40) and a labelled corpus (#44).
