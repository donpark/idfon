# Open Yap 1k turn ranges — notices

## Source

The audio and transcripts this dataset annotates are the public sample of
**Open Yap 1K**, published by [The Agentic Data Company](https://theagenticdatacompany.com/open-yap-1k)
under **Creative Commons Attribution 4.0 International (CC-BY-4.0)**, revision
`a08b1c80e50159d462ddcbbabfdea5bf7ccfc626`.

The 16 conversations are the public sample's preview set: 8.92 h, 48 kHz
dual-channel. The full 1K corpus is distributed separately under a per-recipient
Data Use Agreement and is not the subject of this release.

## What this dataset adds

The source has word-level timestamps per speaker on separate channels but no
turn events. These annotations are ours: the turn-boundary derivation (a maximal
run of one speaker's words with no gap over 300 ms), the event classification
(`handoff`, `silent_tail`, `overlap`, `backchannel`), the two quality gates
(transcript lead coverage and audio channel dominance), and the channel
normalisation (ch0 = the ender).

They are released **CC-BY-4.0** with the source's attribution. The annotations
are keyed to ranges of the source audio; **no audio is included or redistributed
in this repository.**

## The source's rider

The source's licence carries a rider that travels with the files. On the
speakers' behalf, The Agentic Data Company asks that you:

1. do not attempt to identify any speaker in the corpus; and
2. do not use the audio to create voice clones, replicas or generative
   reproductions identifiable as a speaker in the corpus.

Training a general model on the dataset alongside other data is what the
speakers agreed to; the request is about targeting an individual speaker. This
dataset carries no speaker profiles, names or other identities — only the source
conversation key, the channel labels and the times.

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
