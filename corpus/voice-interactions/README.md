# Voice-interaction corpus

Timed, speaker-attributed transcripts of real full-duplex voice-agent
conversations (backchannels, cut-ins, completions, laughs), for replaying
through the on-device voice agent as a **regression hedge**: when the turn
model, the feedback hook, or the mouth changes, re-run these and diff the
decision timeline.

**No audio is committed.** Only text + timings + the replay script. Tests
recreate the caller's side from the timings (TTS-synthesized user speech, the
`-tygerdemo` harness pattern), which keeps the corpus free of the recordings'
copyright. The originals stay on their pages.

| file | origin | highlights |
| --- | --- | --- |
| `dessa-anniversary.json` | block.xyz/dessa "An anniversary surprise" | gasp, backchannels, 9 cut-ins |
| `dessa-dc-comics.json` | "Remembering a movie" | title blank + sentence completion |
| `dessa-ai-release.json` | "Talking about the release" | dense turn-taking |
| `dessa-coffee-ding.json` | "Expressive conversation" | intonation range, overlapping acks |
| `dessa-life-advice.json` | "Life advice" | empathy, long monologues + interjections |
| `dessa-vs-gpt-live.json` | "Dessa in conversation with GPT-Live-1" | AI-vs-AI |
| `tyger-demo.json` | tyger-s2s demo recording | mm-hm over turns, 2 interruptions |

The `turns` array is the clean timed transcript (`spk`, `s`, `e`, `text`;
`speakers.human`/`speakers.agent` name the roles). The `replay` object is the
`-tygerdemo` script (`replies` = the agent's turn texts in order; `demo.bc` =
its short interjections; `demo.barges` = the caller's cut-ins;
`demo.reply_starts`, `demo.user_turns` = the reference timeline to diff
against).

## Replaying

With a caller-side audio file (recreated or side-loaded locally, never
committed):

```sh
IDFON_TTS=phonon Idfon -tygerdemo /path/user.wav corpus/voice-interactions/dessa-anniversary.json
```

Marks (`tygerdemo t=…`, `turn-shadow: …`) are the decision timeline; diff them
against `replay.demo` for regressions. See `mac/Sources/Idfon/TygerDemo.swift`.

## Provenance

- Dessa clips: `block.xyz/dessa` (Block research demos). Transcripts extracted
  from the page's own speaker-attributed subtitle data (verbatim).
- tyger-demo: diarized (FluidAudio nemotron3) + transcribed (Parakeet Redux)
  from the tyger-s2s demo recording.

## Planned (not urgent)

A public Hugging Face dataset of these timed transcripts (text + timings only,
same recreate-from-transcript test recipe), so the corpus can grow beyond what
we hold locally without carrying any audio rights.
