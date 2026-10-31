# The moq fork (`donpark/moq`)

Status: **current**. The media stack (moq-audio/moq-mux/moq-net/moq-video/hang,
moq-tokio) comes from our fork of moq. This doc says why, which branch matters,
and how to update it.

## Why we fork

Four divergences from upstream (as of the 2026-10 re-base):

1. **Decode-side loss recovery** — `Decoder::recover(next, frames_to_next)`
   rebuilds one lost packet from the best source in `opus_demo` order: the
   next packet's in-band forward error copy (LBRR) for the frame right
   before it, its **deep redundancy (DRED)** at that frame's offset for the
   rest of the burst, then concealment; `Consumer`'s `Options::conceal`
   bound (≤ 1 s) fills small undeclared holes with it. A **fully recovered
   hole is not a gap**: the decoder keeps the prediction the recovery built
   and the timeline stays continuous; only an unfilled hole resets and stays
   visible.
2. **A working encoder FEC knob** — `Settings::fec` sets `OPUS_SET_INBAND_FEC`
   *and* `OPUS_SET_PACKET_LOSS_PERC=10`. Upstream removed their flag as
   "ineffective" (`#3841`) because without an expected loss rate libopus writes
   no LBRR copy at all. Ours is the version that works. Policy (user design):
   FEC is mono-only — stereo + LBRR couples the channels (see
   `media-adaptation.md` §B2.4/§D7), so the ladder's stereo step flips it.
3. **`BitrateControl`** — a shareable handle that ABR uses to retune the running
   encoder from outside the publish loop (`Options::bitrate_control`).
4. **libopus 1.6.1 via `opusic-sys`** — moq-audio's codec backends build against
   the maintained C bindings (vendored 1.6.1, `bundled` cc build, `dred` feature)
   instead of upstream's `unsafe-libopus` (c2rust transpile of 1.3.1). 1.6.1 adds
   DRED + deep PLC; deep PLC is free inside the decoder, DRED is wired end to
   end (`Settings::dred` embeds it, `recover` rebuilds bursts from it — the
   option-space analysis lives in `media-adaptation.md` §D7.1).

## Upstream topology (read before updating)

`moq-dev/moq` carries **two living, unrelated lines** (no common git ancestor):

| Line | Branch | What it is |
| --- | --- | --- |
| A | `release` | The lineage our fork shares. **crates.io releases are cut from it**, and iroh-live builds against those releases. This is what we track. |
| B | `main` | A re-rooted, restructured "next" line (new crate layout, MIGRATE.md guides). iroh-live tried it (`a124b82`) and retreated to released crates (`2c6f745`). Not usable with our stack today. |

Our branches on `donpark/moq`:

| Branch | Base | Used by |
| --- | --- | --- |
| `loss-recovery-release` | `origin/release` + our 2 patch commits | **idfon (this repo)** |
| `loss-recovery-0.1` | `origin/main` + the same 2 patches (ported) | nothing yet — kept for the eventual move to line B |
| `loss-recovery-0.0.23` | Frando `iroh-live-3` (the original) | nothing — frozen, rollback reference |

## Update procedure

In the moq clone (`~/dev/moq-upstream`):

1. `git fetch origin release`
2. Replay our two patch commits onto the new head
   (`git rebase origin/release loss-recovery-release`, resolving against any
   new upstream shape — the consumer/encode APIs drift).
3. `cargo test -p moq-audio` (includes the recovery tests: the in-band copy must
   beat concealment against the original).
4. `git push mine loss-recovery-release`

Then in idfon:

5. `cargo update -p moq-audio -p moq-net -p moq-mux -p moq-video -p moq-tokio -p hang`
   (if `cargo update -p moq-net` says "ambiguous", the lock briefly holds two
   instances — see the rules below).
6. `cargo check --workspace --all-targets`, then the test crates.

## Rules

- **One git URL/branch for the whole moq family.** Mixing two git sources, or a
  git source with an unpatched crates.io copy, splits `moq_net`/`moq_mux` types
  into incompatible instances. All six patched crates (incl. `moq-tokio`) point
  at the one branch.
- **`moq-tokio` is patched too**: `iroh-moq` pulls it, and unpatched crates.io
  `moq-tokio` demands a *newer* `moq-net` than the fork carries — which
  resurrects the two-instances split.
- **Version reqs must admit the fork's versions** (release family: moq-net 0.3.x,
  moq-tokio 0.19.x, moq-mux 0.10.x, moq-audio/moq-video 0.1.x, hang 0.21.x).
  The idfon manifests pin these (root `[patch.crates-io]` + the direct git deps
  in `iroh-c-ffi`, `idfon-media`, `idfon-live-media` — grep for `donpark/moq`
  and `n0-computer/iroh-live` to find them all).
- **iroh-live pin**: `n0-computer/iroh-live@9abd29be` (branch `Frando/bump-moq-2`,
  "build against the released moq crates"). It is the bridge between moq and
  idfon (`moq-media`, `iroh-moq`); move it deliberately, and only to a commit
  whose moq reqs the fork satisfies.
- `moq-relay` never enters our dependency graph (iroh-live's workspace lists it;
  `moq-media`/`iroh-moq` do not use it), so its version skew does not matter.
