# Voice agent harness — research notes

Status: **research notes + first decision** (2026-10-11). This file collects what an
agent harness for the idfon voice agent must do, and what already exists in open
source. **Decision (2026-10-11): adopt `yoagent`, behind a thin idfon-owned
`idfon-director` boundary.** The adopt-vs-rewrite question is revisited after the
director is stable. See GitHub #30 (plan) and #31 (the decision). The portable
loop contract (prompt, tool schemas, trace) is `docs/voice-agent-loop-contract.md`.
It is written in Simplified Technical English
(STE-flavored: the structural rules apply, the word-choice rules apply as a
direction). Companion to `docs/voice-agent.md` (the peer), `docs/voice-multimodal.md`
(the turn contract), `docs/voice-decisions.md` (the deciders), and
`docs/voice-agent-prompting.md` §13 (prompt focus and tier split).

How to read this file:

- **Source claim** marks a figure from a project page or a package registry. No one
  re-verified it. Recheck before a decision depends on it.
- **Open item** marks an unknown that blocks a decision.

## 1. What the harness is

The harness is the **agent loop**: model call → tool calls → tool results → repeat,
plus the session state around it. It is not the audio pipeline. In idfon today:

| Layer | Owner | Language |
| --- | --- | --- |
| LLM tool loop | **Eve** (`eve@0.68.0`) | TypeScript / Node |
| Audio and session loop | `crates/idfon-voice-agent` (`cascade.rs`, `gpt_live.rs`) | Rust |
| Live reply generation | Vercel AI SDK (`ai@7`) in `agents/gpt-live-1` | TypeScript / Node |

Eve compiles to a **Nitro + Node** server (`globalThis.__nitro_main__`,
`_chunks/node-server.mjs`, `node:module`). It does not run on-device without a
bundled JS runtime. That is the constraint the on-device conversation director
(`docs/voice-agent-prompting.md` §13) must break.

## 2. Requirements

| # | Requirement | Source |
| --- | --- | --- |
| R1 | Tool-calling loop: model → tool calls → results → repeat | `voice-multimodal.md` |
| R2 | One loop on-device and remote; the prompt and tool schemas are the shared artifact | §13 (Prompt focus) |
| R3 | Provider seam: AFM3 on-device, hosted remote (Jev, Laya, Gateway, GPT-Live) | §13 (Tier split) |
| R4 | Streaming, interruption, and turn hooks (the runtime owns turn-taking) | `voice-agent.md` |
| R5 | Session state and compaction under tight budgets (source claim: Jev 32k, Laya 8k) | `voice-decisions.md` |
| R6 | Multimodal input and output (transcript, crop, camera frame; `speak`, artifacts) | `voice-multimodal.md` |
| R7 | The existing tool set (`speak`, `point`, `show`, `add_artifact`, `screenshot`, camera, `read_reference`, `voice_*`, `context_edit`, MCP) | `eve-idfon`, `eve-idfon-voice` |
| R8 | Transport-agnostic (iroh channel, MCP, `IDFON-*/1` envelopes) | `idfon-eve.md` |
| R9 | Propose versus authorize; fail-open; auditable; deterministic fallback | `voice-decisions.md` |
| R10 | Statically linkable into iOS and macOS, not Node | Eve output |
| R11 | Metrics and observability | `idfon.voice.metrics` |
| R12 | **Subagent support**: the loop can drive the wrapped agent as a child | user decision, 2026-10-11 |
| R13 | **Decision models as tools**: the SystemOne deciders are tools or gates | user decision, 2026-10-11 |

R12 and R13 are new. R12 is the wrapped-agent path (`voice_forward`/`voice_relay`
today). R13 maps `docs/voice-decisions.md` onto the loop.

## 3. The reference shape: pi-agent-core

`@earendil-works/pi-agent-core` v1.1.0 (source claim: 332 KB, **1,429 lines across
5 files**):

- `agent-loop.js` (674 lines): `agentLoop`, `agentLoopContinue`, `runToolCall`.
  The loop works in `AgentMessage` throughout. It converts to provider `Message[]`
  only at the LLM boundary (`convertToLlm`).
- `agent.js` (436 lines): stateful `Agent`. It owns the transcript, an event
  stream, steering and follow-up queues, and an abort signal.
- Hooks: `beforeToolCall`, `afterToolCall`, `prepareRequest`, `prepareNextTurn`,
  `transformContext`, `finishTurn`.
- The provider and transport live in a separate, heavier package (`pi-ai`,
  6.3 MB, many provider SDKs).

The lesson is the shape, not the language: keep the loop small, put the provider,
the transport, and the policy at the edge behind hooks, and convert formats only at
the model call.

## 4. Options in open source

### Rust (the only lane that reaches both tiers)

| Project | Stars | License | What it gives |
| --- | --- | --- | --- |
| `yologdev/yoagent` | 346 | MIT | "The agent loop for Rust." Sub-agents, decision models, session trees, compaction, extensions, WASM. See §5. |
| `initorigin/io-harness` | 5 (v0.86) | Apache-2.0 | Embeddable runtime. Permission boundary, sandbox, budget ledger across a tree, durable SQLite trace, nested sub-agents, mailbox. Maps to R9. |
| `zavora-ai/adk-rust` | 699 | not detected | ADK port with model integrations. |
| `0xPlaygrounds/rig` | 8,854 | — | Larger LLM application framework. |
| `bosun-ai/swiftide` | 789 | — | Streaming indexing and agentic pipelines. |

Apple on-device inference from Rust. **`fm-rs` v0.3.0 is the iOS option**: it
targets macOS 26+ and **iOS/iPadOS 26+**, compiles a Swift FFI layer for the
target, and exposes a `Tool` trait, built-in system tools, `ToolCallingMode`, and
a `private-cloud-compute` feature. `foundation-models` v0.12.0 has the cleaner
Rust API but is **macOS-only**: its build script hardcodes `--sdk macosx`, so it
does not build for iOS. Also present: `apple_ai`, `rusty_foundationmodels`,
`apple-intelligence-models`. `llama-cpp-2` covers llama.cpp.

io-harness notes that **pi has no built-in sandbox by design**, and that its answer
is a contained environment. That matches idfon (no built-in sandbox; capability
grants are the boundary).

### Native

`vercel-labs/fx` — **Zig**, 3,364 stars, Apache-2.0, "Unix like coding agent." It
ships `libfx`: the runtime as a JavaScript API and a **WebAssembly** build. It is a
compact native agent with an embeddable core, not a TypeScript framework. It is a
reference for a small native loop and for a WASM portability story.

`OpenSparX/MasterAgent` — C++17, 1,336 stars, Apache-2.0. Local-first embeddable
runtime. It matches deterministic skills before model inference, validates tool
names and arguments, and writes durable receipts. A good R9 reference.

### Swift / Apple

| Project | Stars | License | What it gives |
| --- | --- | --- | --- |
| `rudrankriyam/FoundationModelsAgent` | 44 | MIT | A harness **around** AFM: approval, allowlist, trusted manifest, per-run tool budgets and timeouts, retries, durable transcript checkpoints, receipts. It deliberately does not own the loop. Source claim: needs iOS 27, Xcode 27. |
| `SwiftedMind/SwiftAgent` | 228 | MIT | Native Swift SDK with agent loops, tool execution, and adapters. |
| `rryam/FoundationModelsKit` | 162 | MIT | Schema utilities, token accounting, conversation state. |
| `osaurus-ai/osaurus` | 8,037 | MIT | A full offline macOS harness. Read it for architecture. |
| `john-rocky/coreai-kit` | 117 | BSD-3-Clause | On-device chat, vision, and speech. |

### TypeScript (remote only)

| Project | Stars | What it gives |
| --- | --- | --- |
| `earendil-works/pi` | 114,305 | The agent toolkit. `pi-agent-core` is its minimal loop. |
| `vercel/ai` | 27,246 | The AI SDK. Its core loop is `generateText`/`streamText` with `stopWhen`. |
| `vercel/eve` | 5,524 | The current harness. Nitro + Node. |
| `openai/openai-agents-js` | 3,905 | Lightweight multi-agent, includes voice support. |
| `withastro/flue` | 8,446 | Sandbox agent framework. |
| `@ai-sdk/harness*` | — | Source claim: experimental. It drives external coding agents (fx, pi, Claude Code, Codex) in a sandbox over ACP. Not a voice loop. |

### Python (read for ideas only)

`huggingface/smolagents` (29,782 stars) is barebones; `openai/openai-agents-python`
(29,967 stars) is lightweight.

## 5. The strong match: yoagent

`yoagent` already implements R12 and R13, in Rust, under MIT.

**Sub-agents (R12).** A parent registers a `SubAgentTool` with its own model, system
prompt, and tools. The parent model calls it like any other tool. Each call starts a
fresh conversation, so no state leaks. Parallel calls run concurrently. Source
claim: `SubAgentTool::from_config`, `Agent::with_sub_agent`, default parallel
strategy.

**Decision models (R13).** The `decision` feature answers typed questions about a
state: `noul` (P(true)), `choice` (one of up to 255), and `score` (2–10 levels).
Source claim: this is **the SystemOne wire vocabulary** (`"type": "noul"`), used by
TypeSafe's Jev, Cloudflare's Clef, OpenAI's Decisions API, and any logprobs server
(llama.cpp, vLLM, SGLang, LM Studio). The module is exposed through
`with_decision_model`, `with_tool_gate`, and `with_input_guard`. It adds no
dependencies.

This is the same contract as `docs/voice-decisions.md` (`choice`, `score`, `noul`;
TypeSafe and Jev; `llama-cpp-classify` on-device). R13 is therefore not just
possible; it is already built, with the exact vocabulary idfon uses.

Other properties: a session tree that forks and checkpoints, tiered compaction,
`Extension` hooks that fail closed, steering of a running turn, sub-agent policy,
audit logs, and a `wasm32-unknown-unknown` target. Cost: source claim, MIT, 28
normal dependencies (tokio, reqwest, serde), MSRV 1.86, ~1.2 MB crate size.

### iOS viability (measured 2026-10-11)

yoagent **0.25.2 compiles and links for iOS**. A probe crate with
`yoagent = { version = "0.25", features = ["decision"] }` and
`crate-type = ["staticlib"]` built clean for both targets:

| Target | Result | Release archive |
| --- | --- | --- |
| `aarch64-apple-ios` (device) | pass | 42 MB; 25 MB after `strip` |
| `aarch64-apple-ios-sim` | pass | — |

With `default-features = false, features = ["decision"]` the device archive is
30 MB. A static archive is dead-stripped when the app links it, so the real
app-size delta is smaller. The dependency tree is tokio, hyper, reqwest,
rustls, and ICU (idna).

Caveats, in order of importance:

1. **Runtime is not proven, only compile and link.** No probe has driven the loop
   on a device or simulator.
2. The default `native` feature enables `tokio/process` and `tokio/fs`. `Command`
   compiles for iOS but process spawning is not App-Store-safe. Do not expose a
   shell tool on-device. Use `default-features = false` and add only what the
   director needs.
3. TLS uses `rustls-platform-verifier`, so iOS checks certificates through
   Security.framework. This is the correct Apple path, and no CA bundle ships.
4. The tokio runtime must run off the main thread. Do not block the UI thread.
5. A voice call is a foreground session, so the iOS background-execution limits
   do not apply to the call itself.

### Runtime probe (macOS arm64, 2026-10-11)

The loop was driven offline on macOS with `MockProvider` (no network, no key). Four
checks passed:

| Check | Result |
| --- | --- |
| Loop plus one tool round trip | The `echo` tool ran once; `ToolExecutionEnd` emitted. |
| Subagent | `SubAgentTool::from_provider` drove a child loop; the tool call executed. |
| Decision evaluate | `MockBackend` returned `NoulAnswer { p_true: 0.5 }` for a noul question. |
| Decision as a tool gate | `ToolGate` wired into the agent; the neutral answer suppressed the `echo` tool (0 runs) and the loop continued. |

The probe is at `/tmp/yoagent-mac-probe`. It proves the loop, tool execution,
sub-agent delegation, and the decision/gate path run on an Apple-silicon host.

### Device runtime probe (iPhone 16, iOS 27.0.1, 2026-10-11)

The same probe plus an HTTPS request ran **on a physical iPhone 16**. A staticlib
(`libyoprobe.a`) was linked into a throwaway SwiftUI/UIKit app and launched with
`devicectl`. Results:

| Check | Result |
| --- | --- |
| A loop plus tool round trip | PASS (echo ran 1x) |
| B subagent | PASS |
| C1 decision evaluate | PASS (`NoulAnswer { p_true: 0.5 }`) |
| C2 decision as a tool gate | PASS (tool suppressed, loop continued) |
| D HTTPS TLS GET (`reqwest` → `rustls-platform-verifier`) | PASS (status 200 OK) |

The whole run took 0.12 s. This closes the iOS-only unknowns: the tokio runtime
runs on-device, and TLS validates through Security.framework with no CA bundle.
The probe crate is `/tmp/yoprobe`, the app is `/tmp/yoapp` (bundle
`app.idfon.yaogprobe`). One trap for the next app: a UIKit app that does not adopt
the scene lifecycle traps with `SIGTRAP` at launch on iOS 27
(`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`), so a scene
manifest and a `SceneDelegate` are required.

### AFM probe (iPhone 16, iOS 27.0.1, 2026-10-11)

Apple Foundation Models was driven **from Rust** on the same device, through
`fm-rs` linked into the same app. Two axes matter: cold compared with warm, and a
**reused session** compared with a **fresh session per call**.

| Phase | Fresh session | Reused session |
| --- | --- | --- |
| `SystemLanguageModel::new()` | 0.002 s (lazy) | — |
| Session create | ~0.000 s | — |
| Plain reply | 0.97–1.07 s | 0.24–0.26 s |
| Structured reply (`respond_structured`) | 1.14–1.26 s | 0.70–0.92 s |
| Tool round trip | 1.77–1.97 s | 1.26–1.34 s |
| First generation after load | 1.23–1.45 s | — |
| Model availability | `Available` (Apple Intelligence on) | |
| Native tool call to a Rust `Tool` impl | called on every request (4/4) | |

Reading:

- **The cold cost is one-time and load-shaped.** Model construction is lazy. The
  first generation pays about 1.2 s of load.
- **Session reuse is the largest lever.** A fresh session costs ~1.0 s for a plain
  reply; the same session warm costs ~0.25 s. The director must keep **one
  persistent session for the call**, not create a session per decision.
- **Plain warm inference is ~0.25 s**, inside the decision budget in
  `docs/voice-decisions.md` (Jev and Clef: 230–444 ms per gate check). A plain
  answer that the code parses is the fastest decision shape.
- **Structured output is ~0.8 s warm** (heavier than plain, lighter than a tool
  round trip). Use it for richer judgments, not for the fast per-turn decisions.
- **A tool round trip is ~1.3 s warm** (about two model passes). That is a
  workflow step, not a per-turn decision.

**Prewarm decision (idfon, 2026-10-11).** The contact is known before the call, so
the app can **load the model during call setup** (ringing and connection) and keep
one warm session for the call. That hides the ~1.2 s load and amortizes session
setup behind a delay the caller already experiences. Prewarm only for the contacts
that need a voice agent. A human contact does not need a voice agent until in-call
assistant agents exist.

**OS floor (idfon, 2026-10-11).** AFM3 needs **iOS/macOS 27+**. A device below the
floor cannot run the on-device director, so it uses the **remote voice agent**. The
two-tier design already allows this per contact (the ticket names the provider).
Note: `fm-rs` declares iOS/iPadOS 26+; verify the exact floor before the skill
states it.

## 6. Recommendation

- **Adopt `yoagent`** for the real harness (decided 2026-10-11, #31). It already has
  R12 and R13, it is Rust (so it can run on-device and remotely), and its decision
  feature speaks the idfon decider contract. The dependency objection is moot: the
  idfon iOS app already links reqwest (991 symbols), tokio (4,550), rustls (2,443),
  and hyper (1,392); only `kameleoon-reqwest-eventsource` is new. Keep it behind a
  **thin `idfon-director` boundary** (turns / tools / trace), so the loop stays
  swappable. Read `io-harness` next for the R9 layer (budget ledger, durable trace,
  permission boundary).
- **Use pi-agent-core as the shape reference.** If the boundary is ever swapped for
  a hand-rolled loop, target about 1,400 lines (loop + state only; parity with
  `yoagent` is larger).
- **Bridge AFM3 in Rust** with the `fm-rs` crate (iOS-capable; §4), behind the
  `yoagent` provider trait. Then one loop serves both tiers, and the prompt and tool
  schemas are the portable artifact (R2).
- **If on-device must be Swift**, start from `FoundationModelsAgent` (policy and
  checkpoints) plus `FoundationModelsKit` (schemas and tokens) plus `SwiftAgent`
  (the loop), and accept two implementations with a shared prompt.
- **Read `fx`** for a compact native loop and the WASM story. It is not a Rust or
  Swift dependency.
- **Skip** `@ai-sdk/harness` and the ACP adapters. They drive external coding
  agents in a sandbox; they are not a voice loop.

**Optimization surface (idfon direction, 2026-10-11).** A Rust loop makes the
prompt and the policy a programmable surface. A **GEPA** loop can optimize the
voice-agent prompt from run traces, and the same traces can drive RL. `yoagent`
exposes the provider, tools, and extensions as traits, so the loop can be
observed and changed without a fork. Keep the prompt and the tool schemas as
data, and export run traces for the optimizer.

## 7. Open items

- **Decision shape.** AFM structured output is ~0.8 s warm and a plain reply is
  ~0.25 s (§5). Decide which director decisions use a plain answer that code
  parses, which need a schema, and which stay with the small decision model.
- **Prewarm and session persistence.** Confirm on a real call that call setup
  hides the ~1.2 s load, and that one warm session survives a multi-minute call
  without a reload.
- **Tool-call latency.** A warm tool round trip is ~1.3 s. Decide which director
  actions can wait that long, and check `fm-rs` `ToolCallingMode` and prompt size
  for a cheaper path.
- **Wrapped agent as a subagent.** `yoagent`'s `SubAgentTool` runs a local child
  loop; the wrapped agent is a remote idfon peer. Confirm that a child loop can be
  replaced by a remote call over the channel, or model it as a normal tool.
- **Decision tool granularity.** One `decide` tool, or one tool per decision. The
  batching rule in `docs/voice-decisions.md` says decisions that share a moment
  batch into one call.
- **Optimization loop.** Define the trace format that a GEPA prompt optimizer or
  an RL loop consumes, and keep the prompt and the tool schemas as data (§6).
- **License review.** Confirm every candidate license before adoption. Several
  projects in §4 show no detected license.
- **Sub-agent authority.** R9 applies to child loops too: a child proposes, code
  and capability grants authorize, and a child cannot raise the parent's budget.
- **Revisit adopt-vs-rewrite.** After the director is stable, during optimization.
  The trigger is whether `yoagent`'s extension hooks express idfon's authority/lease
  model. If they cannot, the thin boundary becomes a fork (#31).

## 8. References

- `@earendil-works/pi-agent-core` — `dist/agent-loop.js`, `dist/agent.js`,
  `dist/agent.d.ts`.
- Eve default harness — `node_modules/eve/docs/concepts/default-harness.md`:
  "the default harness is eve's built-in agent loop."
- Eve output — `agents/voice/.output/server/index.mjs`,
  `_chunks/node-server.mjs`.
- `https://github.com/yologdev/yoagent` — decision models, sub-agents,
  `examples/sub_agent.rs`.
- `https://github.com/initorigin/io-harness` — composition, durable runs.
- `https://fx.sh/docs/lib` — libfx, Node.js and WebAssembly.
- `https://github.com/rudrankriyam/FoundationModelsAgent`,
  `https://github.com/SwiftedMind/SwiftAgent`,
  `https://github.com/rryam/FoundationModelsKit`.
- `crates.io` — `foundation-models`, `llama-cpp-2`, `yoagent`.
