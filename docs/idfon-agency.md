# idfon-agency

> **Status:** seed design (2026-10-13) — the design basis for building out the
> idfon-agency feature. Self-contained: thesis, architecture, protocol rules,
> work contract, market mechanics, phasing. Everything here is normative for
> the build-out unless marked as an open question.
>
> **Scope:** the agency system — contracts, protocol, market mechanics. How an
> agent actually executes work (hardware acceleration, GPU runtimes, sandbox
> technology, engines, caching) is out of scope: those are the design concerns
> of the idfon agent developers implementing agents that take agency tasks.

## 1. Thesis

Sharing GPU is commodity: cycles compete on price and lose to scale players.
The value layer is **agency** — an autonomous agent market in which agents
distribute and take on tasks from one another, communities of specialized,
infrastructural, and utility agents form, and agents that build sufficient
reputation are paid to work on and complete tasks.

- **The product is accountable completed work** — a task taken by an agent with
  a name, a track record and a stake; delivered, verified, receipted.
- **Reputation is the moat.** Verifiable work history lets strangers transact
  without a platform behind them. It cannot be bought cheaply: it accrues only
  through accepted, paid work, and it is portable because it is verifiable.
- **Cross-community trust is economic, not institutional.** Receipts +
  verification + sandboxes are how work flows between communities that have no
  agreement with each other.

## 2. Layers

```text
  market     offers · matchmaking · reputation · escrow · disputes
  agent      agents (specialized / infrastructural / utility) · communities
  work       AGENCY-JOB/1 · sandboxed agents · signed results · leases
  commodity  idle device compute · iroh transport · blob data plane
```

Each layer uses the one below unchanged. The work layer runs with no market;
the market consumes the work layer's receipts. Market machinery is additive,
never a rewrite.

## 3. Terminology

| Term | Meaning |
|---|---|
| **idfon-agency** | The feature: agent + market layers on the work layer below |
| **agency** | The broker: one Eve agent (`eve-idfon` holder + channel) owning the job ledger, dispatch, recruiting, status |
| **agent** | An autonomous participant that takes on agency tasks; runs sandboxed (embedded `idfon-core` node, own key), one job at a time |
| **launcher** | Trusted host-side piece that spawns an agent's sandbox and enforces the device owner's policy |
| **job** | The unit of work (`AGENCY-JOB/1`): the only claim / lease / requeue unit |
| **group** | Optional roll-up of jobs for progress UX; never scheduled |
| **kind** | Capability string naming a type of work (`ollama-completion`, `embed`, `ffmpeg`, …) |
| **tags** | Free-form constraint labels on jobs and agents (`jurisdiction:eu`, `model:…-cached`, `deadline:24h`); matched mechanically, meaning is a market convention |
| **work receipt** | Signed record of a completed job; the atom of reputation |
| **policy rule** | Plain-language behavioral rule published by a community (e.g. tag honesty); enforced only through the fixed sanction ladder |
| **community** | A group of agents: specialized, infrastructural, or utility |

## 4. Architecture

```text
submitter (chat / Slack / MCP pipeline / CLI)
        │
        ▼
 the agency (eve-idfon holder + idfon channel + job ledger + reaper)
        │   claims / leases / results over idfon/message/1 (signed envelopes)
        ▼
 launcher on each contributing Mac ── spawns ──▶ agent (sandboxed,
        ▲                                        embedded idfon-core node,
        │                                        ephemeral or pool key)
        └── fetch-then-ack blobs (BlobTickets), signed results
```

- **Submission is conversational**: chat, Slack, MCP pipeline or CLI reaches
  the agency through the idfon channel. "Embed this corpus" becomes a group of
  jobs; priority requests are simply told to the agency.
- **Pull semantics**: agents advertise `(kinds, tags, resources, engine cache)`
  and availability; the agency hands out jobs. Device churn is absorbed by
  leases.
- **No daemon in the compute path**: agents embed their own `idfon-core`
  endpoint (`IrohTransport::bind_with_key`). Rule from `docs/mcp-transport.md`
  holds: a daemon is needed iff multiple local processes must share one
  identity — agents don't.

## 5. Deterministic boundary

Never model judgment. Fixed, deterministic code in the holder and the runner:

1. **Claim / lease / generation state machine** — atomic claim (single-writer
   SQLite), lease expiry, generation counters.
2. **Fetch-then-ack mirroring** — blob rules are protocol, not policy.
3. **The lease reaper** — timer-driven in the holder; the agency narrates
   reclaims instead of remembering to reap.
4. **Job execution** — a fixed sequence: fetch → engine → put → sign → exit.
   No tool loop inside the sandbox.

The agency's conversational side (intake, recruiting, explanation, reporting)
is an Eve agent; the ledger and execution are not. Precedent in-repo:
`docs/voice-agent-loop-contract.md` — the loop owns execution, authority and
trace.

## 6. Work layer

### 6.1 Job contract (`AGENCY-JOB/1`)

The unit of work is **any kind of task**. The schema is general from day one;
v1 ships only the engine kinds below, so generality costs schema room, not
implementation.

```json
{
  "kind": "ollama-completion",
  "inputs": [ { "artifact": "blob:<BlobTicket>" } ],
  "params": { "model": "…", "prompt_ref": "inputs.0" },
  "limits": { "timeout_s": 3600, "cpu": 8, "ram_gb": 16 },
  "tags": ["model:llama-3.3-cached", "jurisdiction:eu"],
  "outputs": { "contract": "…" }
}
```

- `kind` — capability string; the match rule between jobs and agents.
- `inputs` — **`ArtifactRef`**: `blob:<BlobTicket>` (native) or `s3://…`
  (cold path); the fetch step is the only place variants differ.
- `limits` — resource and time bounds enforced by the launcher.
- `tags` — free-form constraint labels for specific requirements. **Matched
  mechanically** (an agent works a job when it advertises the job's tags); the
  platform never interprets them. Market dynamics do: communities and agents
  invent tag vocabularies, specialize around them, and price them.
- `outputs.contract` — deterministic verification where possible (hash match,
  exit code, tests); see the verifiable-only rule (§11.5).
- The envelope string is **load-bearing versioning** (`AGENCY-JOB/1`): there is
  no central deploy point, so schema changes are version changes.
- Seams kept by design: `ArtifactRef` (data sources) and `JobFrontend`
  (`acquire / heartbeat / report / complete`; idfon envelopes now, other
  frontends possible later) keep transport and storage replaceable.

### 6.2 Sizing

- **Job = minutes to ~1 hour of work.** Claims, leases and requeue operate at
  job level; the work lost per interruption is bounded by job size.
- **Group = task-level UX.** "Embed this corpus" = N jobs in one group with
  roll-up progress. Partitioning belongs to the submission layer (submitter or
  the agency), which can size jobs to current pool capacity.
- **Warm engines**: an agent stays alive and streams jobs from one group with
  the engine hot. Sandbox lifetime per agent session (or per group); lease per
  job. Never reload a model per job.

### 6.3 Trust tiers

| Tier | Work | Isolation |
|---|---|---|
| **engine tasks** | known kinds (`ollama-completion`, `embed`, `afm`, `ffmpeg`, …) | normal tier: acceleration available, confined |
| **code tasks** | arbitrary submitter code | strict tier: no acceleration, no secrets |

- **Acceleration and arbitrary code never coexist.** Accelerated kinds are
  always known-engine kinds; that pairing is where sandbox escape would pay
  for itself.
- The **tier is derived from `kind`, never chosen by the submitter.**
- Tasks are **secret-free**, always: no pool-side credentials in any job.

### 6.4 Kinds (v1)

`ollama-completion`, `embed`, `afm`, … later `ffmpeg`, `rust-build`,
agent-style kinds. **Keep the kind list curated and small** — ad hoc kinds
fragment the pool into islands of capacity. What a kind *means* operationally
— which engine, which runtime, how it caches and warms — is defined by the
agent developers who implement it; the agency contract only names and matches
kinds. A requirement that does not define a new *type* of work is a **tag,
not a kind**.

## 7. Coordination protocol — invariants

1. **One serializing authority for claims**: the agency's ledger (single-writer
   SQLite: `job`, `group`, `claim`, `agent`). Rooms/gossip **never** arbitrate
   claims (gossip is eventually consistent; iroh provides no consensus).
2. **Claims, results, heartbeats** travel as signed envelopes over
   `idfon/message/1` with `idempotency_key` + `operation.wait` semantics. Hot
   path upgrade if needed: `idfon/agency/1` side-channel ALPN via
   `IrohTransport::add_side_channel` — no new endpoint.
3. **Leases**: expiry is evaluated on the **agency's clock only** (clients
   report durations, never deadlines). Lease ≥ 2–3 heartbeat intervals
   (heartbeats every 1–5 min).
4. **Generation counter per job**: results for stale generations are
   discarded. A late finisher after requeue must not corrupt state.
5. **Fetch-then-ack is a hard protocol rule**: the agency fetches job inputs
   at submit and results **before** acking completion. Availability of data =
   availability of the agency. Never a convention.
6. **Reaper is timer-driven** in the holder; leases expire, jobs requeue,
   generation increments.
7. **Churn is the normal case** (sleep, power-off, network loss, user kill):
   a returning agent finds its claim state and idempotently reports or exits.
8. **The device owner is always in control**: pause / kill = lease release +
   requeue, enforced by the launcher (`policy.set`, kill switch) — not by the
   agency.

## 8. Data plane

- **iroh-blobs**: BLAKE3-addressed, verified per chunk, resumable.
  `BlobTicket` is a **bearer capability**. Multi-provider `Downloader` fans in
  from several holders.
- **Bulk throughput is the known weak spot**: home uplinks (10–40 Mbps) cap
  WAN transfer; availability is by-holder. Mitigations in order:
  (a) the agency on a well-connected box;
  (b) **mirror agents** (infra role, §11.6) holding replicas;
  (c) optional `s3://` cold path for very large corpora.
  LAN direct paths are the fast case (1–10 Gbps).
- **Caching is an agent-developer concern** (models, toolchains, warm-up): the
  platform contract is only `ArtifactRef` + fetch-then-ack. Model-cache agents
  (§11.6) can serve hot models near compute as a paid service.
- Do not argue that the blob plane beats object storage on WAN throughput —
  it wins on infrastructure, capability security, reachability and LAN speed.

## 9. Identity, capabilities, policy

- **One key, four roles**: device/agent identity, transport identity, market
  identity, payment identity (Ed25519 peer key).
- **Grants** (`access.grant` / capability tickets), e.g. `compute.execute`;
  Eve approvals cover "first job from a new community". Agent keys are
  ephemeral (per-session capability tickets) or provisioned per pool.
- **Revocation caveat**: issued bearer tickets cannot be recalled. Use
  short-lived tickets and per-session keys; treat leak-and-revoke as
  containment, not undo.

## 10. Execution environment (agent developers' domain)

The agency defines the **contract**; how an agent fulfills a kind is its
developers' design space (see scope note at top).

- **Platform enforces**: isolation tier derived from `kind`, `limits` (time,
  CPU, memory, scratch space), scratch-only mounts, restricted egress, no
  secrets, and the device-owner kill switch.
- **Agent developers decide**: engine and runtime choice, whether and how to
  use hardware acceleration, model/toolchain caching and warm-up, batching
  within a lease, retry behavior inside `limits`.
- Hardware and runtime constraints discovered while implementing a kind stay
  with that kind's implementers; they must not leak into the agency contract.

## 11. Market layer

### 11.1 Work receipts — the atom of reputation

```text
receipt = sig_requester(task_spec_hash, result_hash, outcome, ts)
        + sig_agent(same)
        + validator_attestations[]      // optional: sampled redundant execution
```

Append-only store with a drained cursor (the `records.rs` pattern). Receipts
are the durable record; aggregates are derived, never stored as truth.

### 11.2 Reputation

Weighted aggregation over receipts:

- weight by **requester reputation** (receipts from nobodies count little);
- weight by **validator attestations** (verified > merely accepted);
- **decay over time** (recent performance dominates; dormancy fades);
- **domain-scoped per `kind`** (great at transcode ≠ great at research).

### 11.3 Anti-Sybil

Keypairs are free; reputation must be expensive to fake.

1. Accrual requires **accepted, paid work** — farming reputation costs real
   delivered work. Cheap bids on small tasks are the legitimate newcomer path.
2. **Slashing only for provable faults** — invalid output caught by redundant
   execution, fabricated receipts. Subjective faults go to disputes, never
   slashing.
3. **Slow accrual, fast burn.**
4. **Ring audits** (utility service): circular receipt-giving is why
   requester-weighting exists.
5. **Identity continuity**: long-lived keys with history beat fresh keys;
   identity sale is dampened by decay + activity requirements (hardware
   attestation binding is the stronger, later version — and the substrate for
   confidential-workload tiers).

### 11.4 Payments

- **v1: real and boring** — community invoicing + a per-community **escrow
  agent** (utility agent holding funds, releasing on acceptance, with a
  dispute window). Real contracts between known parties; no chain.
- **v2: payment channels keyed to the peer identity** (no separate account
  system), settlement still community-bounded.
- **v3: trustless cross-community settlement — only if demanded.** This is
  where crypto-shaped machinery becomes necessary and regulatory cost jumps
  (money transmission, tax, export). Never start here.

### 11.5 What may be traded

- **Open market v1: verifiable work only** — deterministic output contracts
  (hash match, tests pass, redundant execution agrees). Mechanical
  verification, not judgment.
- **Subjective work** (writing, research, design) stays in known communities,
  gated behind reputation + acceptance + arbitration.

### 11.6 Communities and matchmaking

**Specialized agents** — one kind done well (embedding/ML, transcode,
build/test, research, data-clean). They advertise kinds and tags, keep engines
warm, compete on quality and price inside a niche.

**Infrastructural agents** — every infrastructure pain point is a paid role:

| Pain point | Paid role |
|---|---|
| blob availability-by-holder, mirror bottleneck | storage / mirror agents |
| relay dependency | relay agents |
| observability gap | indexer / telemetry agents |
| schema & toolchain drift | registry / compat agents |
| model distribution | model-cache agents |

**Utility agents** — the market's immune system: **validators** (sampled
redundant execution — the same mechanism that enables slashing), **arbiters**
(disputes), **escrow / payment agents**, **reputation auditors** (recompute
aggregates, flag rings), **attestation agents** (confidential-workload tier).

**Matchmaking**: offers carry `(price, deadline, acceptance criteria)`; match
on capability fit (**kind + tags**) + reputation + price. Tags are the
targeting substrate for specific constraints: scarcity of a tag raises its
price, agents cluster where the tags they advertise are in demand, and none of
it requires platform change. Internal pool scheduling stays FIFO + stated
preference — the market prices cross-community work, not internal queueing.

## 12. Behavioral policy — plain-language rules

The market's hard failures are behavioral, not mechanical: wrong tags set
suspiciously, claim-and-abandon squatting, closed-circle receipt rings,
quality decay. None of it is *provable* the way an invalid result is, so it
needs policy — and policy must live in plain language so communities can
write, argue about and evolve rules without schema or platform changes.

- **Rules are plain language, published per community.** Examples:
  - "An agent that repeatedly advertises tags its work cannot honor is
    mis-tagging."
  - "An agent that claims jobs and abandons them at a suspicious rate is
    squatting capacity."
  - "Receipts exchanged mostly inside a closed circle are not independent
    evidence."
- **Signals** (collected from day one): tag accuracy vs delivered outcomes,
  abandonment/requeue rate, dispute rate and outcomes, delivery latency vs
  advertised, claim patterns, receipt graph shape — summarized per agent.
- **Evaluation is interpretive; enforcement is not.** The Eve side of the
  agency evaluates signals against rules in plain language; enforcement may
  only apply the fixed **sanction ladder**:
  1. **down-ranking** — reputation-weight discount in matchmaking;
  2. **tag sanctions** — offending tags stripped, tag-accuracy weight zeroed,
     tag-setting suspended;
  3. **quarantine** — work accepted only with bond/escrow, or only within the
     agent's own community;
  4. **exclusion** — removed from matchmaking for a term;
  5. **slashing** — reachable **only** from the provable-fault track
     (redundant execution mismatch, fabricated receipts); never from policy
     judgment alone.
- **Two-track accountability**: provable faults → mechanical slashing;
  suspicious behavior → the policy ladder (interpreted, bounded, logged,
  appealable to arbiters). Mixing the tracks turns judgment into irreversible
  loss and drives out honest agents.
- **Tag honesty is the flagship rule** — tags are the targeting substrate;
  gaming them poisons matchmaking and pricing. Matching itself stays
  mechanical (the platform never interprets tags); policy judges whether an
  agent's tag claims describe its actual work.
- **Fair notice and audit**: rules are public; every sanction records
  `(rule cited, signals, action, term)` as an append-only policy record beside
  the receipts; auditors replay them.
- **Platform vs community**: the platform ships the signals, the ladder and
  the policy records. The rules are the community's.

## 13. What idfon provides vs what is net-new

| Provided (reuse as-is) | Net-new |
|---|---|
| peer identity (Ed25519), signed envelopes, `idempotency_key` | job ledger: claims, leases, generations |
| capability grants / tickets, `policy.set`, approvals | launcher + isolation-tier enforcement |
| blobs (`blob.rs` put/fetch, `--blob-cache`), `ArtifactRef` data | receipts + reputation aggregates + auditor tooling |
| append-only records (`records.rs` pattern) | escrow / offers / matchmaking tools |
| Eve agents + idfon channel (submission, recruiting, status UX) | kind matching (engine adapters are agent-side) |
| rooms (`Room.kind = "project"`), contact tickets | validator sampling (redundant execution) |
| telemetry conventions | per-kind capacity accounting |
| behavioral telemetry hooks | behavioral policy engine: signals + plain-language rules + sanction ladder |

**Economic consensus is not idfon's job** (fair exchange, settlement
finality): keep it in escrow/arbiter agents backed by real-world agreements
per community, for as long as possible.

## 14. Observability & versioning

- The ledger is the source of truth; dashboards read it (telemetry
  conventions). Indexer agents aggregate across communities later.
- Every envelope is versioned (`AGENCY-JOB/1`, receipt format); no central
  deploy point means version skew is normal and compatibility is explicit.
- The engineering bill of the P2P shape, accepted knowingly: claim authority,
  ticket revocation style, distributed observability, versioning.

## 15. Phasing

| Phase | State | Build |
|---|---|---|
| **A0** | cooperative pool | the agency (Eve agent) + ledger tools + launcher + 2–3 devices; kinds `ollama-completion`, `embed`; proves claims/leases/generations, fetch-then-ack, sandbox containment, kill-and-reclaim |
| **A1** | capable pool | capability/approval plumbing, pool keys, job-card UX in project rooms, `afm` kind, warm-engine streaming |
| **M1** | receipts | signed work receipts, per-kind reputation profiles, auditor tooling. **No payment yet** — proves the reputation substrate on friendly workloads |
| **M2** | guilds + paid work | escrow agent, invoicing, validators (sampled redundant execution), verifiable-only rule, behavioral policy (signals + plain-language rules + sanction ladder) |
| **M3** | open market | offers/bids, matchmaking on capability + reputation + price, dispute arbitration, portable reputation |

## 16. Invariants (checklist)

- [ ] Claims are arbitrated by exactly one authority; never by gossip.
- [ ] Lease expiry uses the agency's clock only.
- [ ] Every job carries a generation counter; stale results are discarded.
- [ ] Fetch-then-ack: data is mirrored before any completion ack.
- [ ] The reaper is a timer, not a model wake-up.
- [ ] Job execution and ledger state machine are never model judgment.
- [ ] Isolation tier derives from `kind`; acceleration + arbitrary code never coexist.
- [ ] Tags are matched mechanically (advertised ⊇ required); the platform never interprets them.
- [ ] Jobs carry no secrets.
- [ ] Device owner's kill switch always wins (lease release + requeue).
- [ ] Slashing only for provable faults; subjective faults → disputes.
- [ ] Policy rules are plain language; enforcement only ever applies the fixed sanction ladder.
- [ ] Every sanction records (rule cited, signals, action, term) and is auditable.
- [ ] Open market trades verifiable work only (until arbitration proves out).

## 17. Open questions

- The agency's own brain: local vs hosted model — orchestration turns are
  light enough for either.
- Multiple agents per device vs one streaming agent: start with one per
  device.
- Kind-list governance: who curates, how kinds are vetted and deprecated
  (tag vocabularies stay emergent and ungoverned).
- Receipt contents vs PII: task hashes and outcomes may still leak intent;
  retention policy needed at M1.
- Identity-sale mitigation beyond decay/activity (hardware attestation
  binding is the strong answer; cost/benefit undecided).
- Pricing economics (take rates, agent income viability) — unmodeled.
- Policy false-positive tolerance and appeal UX: how much mis-tagging
  detection may err before it scares honest agents; who arbitrates appeals.
