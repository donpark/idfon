# Manually testing artifacts and references

> Short runbook for the multimodal artifact loop on `routing`. What to do, and
> what "working" looks like at each step. Written 2026-09-29.

The loop under test:

```
ask (voice/text) -> agent add_artifact -> card in thread -> open detail
  -> select text / image region / HTML element -> Ask
  -> reference chip -> send -> agent reads the selection -> answer
```

## Setup

```sh
pnpm eve build                                  # extension + agents
AI_GATEWAY_API_KEY=... scripts/live-voice-serve.sh   # holder + agent (foreground)
```

Pair the app(s) as in `docs/live-voice.md` ("Pairing the Apple apps"):
`pnpm pair --eve-ticket "$(head -1 ~/.idfon/live-voice/holder.ticket)"`, then
launch the app with its `-pair-ticket <holder-endpoint-id> <capability-ticket>`.
Build the app from this branch (`bash mac/build.sh`, or `bash ios/build.sh`).

## Test it

1. **Produce an artifact.** Send `make an HTML report of three bullet points about otters, as an artifact`.
   - **Expect:** a short text reply and an artifact card in the thread.
   - The model chooses to call `add_artifact`; if nothing appears, say "put it in an artifact" explicitly.
2. **Open it.** Tap the card.
   - **Expect:** the detail screen loads the bytes. HTML renders in the web view; JSON/CSV/text render natively; an image shows zoomable.
   - **If it says "Could not load artifact":** that's the blob-fetch path (the `PeerOffline` fix is unverified). Note the error text and whether the holder process is alive; this is the first thing to chase.
3. **Point at a part and ask.**
   - **Text/data artifact:** select a line → **Ask** → the composer shows a chip → type a question → send.
     **Expect:** the agent answers about the selected text (`read_reference` returns it exactly).
   - **HTML artifact:** tap **Select** → tap an element → **Ask** → chip → ask.
     **Expect:** the agent answers about that element's source.
   - **Image artifact:** drag a region → **Ask** → chip → ask.
     **Expect:** *if the model can see images*, an answer about the region; **if not**, an explicit "I can't see the region" (the fallback). Either way is useful — the first confirms the vision path, the second tells us we need one.
   - **By voice:** with a chip showing, tap the mic, speak the question, send.
     **Expect:** the agent answers about the selection. Note: a memo carries the selector but **not** a region crop (only coordinates + quote).
4. **Links/timers don't escape.** In an HTML artifact, a remote `<img>`/link should not load or navigate — the web view has no network and cancels off-scheme navigation. That's intended, not a bug.

## What to record

- Whether each artifact **rendered**, and whether the **region answer** showed understanding or the "can't see" fallback.
- Any `PeerOffline` in the daemon side, and whether a retry loaded the blob.
- Whether the **reference chip** appeared and the outgoing turn showed as a reference.

## Expected limitations (not failures)

- **json-render / native tree:** structured results render as text for now.
- **Time-range** selection: no UI for audio/video.
- **Memo + region crop:** no crop attached (holder stages one attachment per turn).
- **HTML remote resources / links:** blocked by design.
- **No device run yet:** this is the first end-to-end pass; treat any break as information, not a regression.
