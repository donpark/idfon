# Disk hygiene: Core AI and ANE leftovers

The recurring ~300 GB "System Data" balloon (2026-10-23, 2026-10-27) is the ANE
compiler's leftover state from model loads. This doc says what collects where,
how to list and clean it, and the output contract for scripts and agents.

## The mechanism

Every runtime load of a **source** `.aimodel` makes the Core AI runtime attempt
an ANE compile. The attempt repeats at **every load** — even in the same
process, even when nothing changed — because the ANE compile never succeeds for
these graphs (the fp16-cast constraint, then the `dummy_pool` compiler defect),
so no ANE plan is ever cached to reuse. The GPU plan *is* cached (warm loads run
in ~0.5 s), but each attempt leaves:

| Leftover | Where | Reaches |
| --- | --- | --- |
| `mpsgraph-*` compile workdirs, `*_main.ir` dumps | `$TMPDIR/com.apple.MetalPerformanceShadersGraph/`, `$TMPDIR/` | user, deletable |
| cache registrations | `~/Library/Caches/coreai-cache/` | user, deletable |
| daemon ANE caches | `/Library/Caches/com.apple.aned`, `com.apple.aneuserd`, `com.apple.amsengagementd.classicdatavault` | datavault-locked: stat-denied even as root; a reboot flushes them |

The reusable artifact that skips the compile path entirely is the AOT-compiled
container `<name>.compiled.aimodel/<name>.<arch>.aimodelc`:

- The Swift loaders (`CoreAITurnModel.prepare`) prefer it — zero compile
  attempts (verified: fresh-process runs accumulate zero disk).
- The export pipeline (`ports/tyger-coreai/export_turn.py`) auto-compiles each
  export (scoped `--architecture`, never unscoped) and skips the compile when
  the container's `sourceHash` already matches the source `main.hash`.
- The Python binding (coreai-core 1.0.0b3) **cannot** load `.aimodelc`, so every
  harness process pays one compile attempt per model load. Run suites in few
  processes.
- iOS ships source `.aimodel`, so the app recompiles per launch (accepted
  pending a per-arch pack — see the scratchpad).

## Tools

| Command | Does |
| --- | --- |
| `pnpm ane list` | lists the leftovers with sizes and keep/prune verdicts |
| `pnpm ane clean` | sweeps scratch older than 1 h, prunes stale cache registrations, prints the df delta |
| `pnpm ane clean -- --flush` | also tries `sudo killall aned aneuserd` (the on-demand-flush experiment) |
| `scripts/coreai-cache-prune.sh [assets-dir]` | the cache-prune step alone |

Rules the tools apply:

- **Keep-rule**: a cache registration stays when its hash matches a current
  asset's `main.hash`. `unknown/` registrations are keyed by a runtime-internal
  hash we cannot derive, and the next load recreates them — they stay while
  younger than 14 days.
- **Age gate**: scratch younger than 1 hour is never touched (a compile in
  flight is safe).

## Output contract (for scripts and agents)

`stdout` is line-oriented records: `key=value` pairs separated by single
spaces. Lines start with `kind=` (one leftover) or `summary` (one aggregate
line). Human notes go to `stderr`. Exit codes: `0` ok, `1` measurement failed,
`2` bad usage.

```
kind=scratch path=… bytes=… age_s=…
kind=cache path=… identity=… hash=… bytes=… status=keep|prune
kind=daemon-cache path=… bytes=unknown note=stat-denied-datavault
summary scratch_items=… scratch_kb=… cache_items=… cache_kb=… cache_stale=… daemon_caches=…
summary scratch_swept=… cache_pruned=… aned_flush=done|skipped|failed avail_kb_before=… avail_kb_after=… freed_kb=…
```

Example (an agent decides whether to clean):

```sh
pnpm ane list | awk '/^summary/ {print}'        # aggregate first
pnpm ane list | awk '$1 ~ /status=prune/'       # what clean would remove
pnpm ane clean | awk '/^summary/'               # do it, keep the delta
```

## Measuring and the flush experiment

- Judge every reclaim by the df numbers in the `summary` line, **never by du** —
  du over-counts APFS clones (2026-10-27 lesson).
- For the daemon caches, the deep check is
  `diskutil apfs list | grep -A2 disk3s5 | grep Consumed`.
- `--flush` is an unverified experiment (2026-10-23): if `avail_kb` jumps after
  the daemon kill, an on-demand flush works and `pnpm ane clean -- --flush`
  replaces the reboot. If it stays flat, only a reboot flushes the daemon
  caches — run it a second time to confirm before trusting either verdict.
