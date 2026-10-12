# Reply blocks

What an agent's answer *is*, on the wire and in the apps. A reply is a visible
preamble plus ordered `IDFON-*/1` envelopes. Those envelopes already are blocks;
`crates/idfon-protocol/src/blocks.rs` names them, so every shell renders the
same set the same way, and gives each one an id, so a later block can replace
an earlier one instead of stacking up.

## The set

| Block | Envelope | Renders as |
| --- | --- | --- |
| `Text` | the preamble itself | a bubble, nothing spoken |
| `Speak` | `IDFON-SPEAK/1` | spoken aloud, and shown as the transcript of what was said |
| `Artifact` | `IDFON-ARTIFACT/1` | a card, tap for the detail screen |
| `View` | `IDFON-POINT/1` / `IDFON-SHOW/1` | open an artifact, optionally at a selection |
| `JsonRender` | `IDFON-RENDER/1` | a declarative tree drawn natively from the app's catalog |
| `Reference` | `IDFON-REF/1` | the selection this turn asked about |
| `Unparsed` | anything else | kept verbatim; a shell may still understand it |

The set is deliberately small. `Unparsed` is the growth path: a new envelope is
readable before the model knows it.

## Rules

**Tools produce blocks; prompts carry intent.** Blocks are emitted by tools and
ordered by the outbox, never written by the model as syntax. A model asked to
format its own blocks invents vocabulary — on the image turn it fabricated a
tool named `image` from the prompt's own `[image] …` line. Keep the producer
side as tool calls or structured output, and the wire as blocks.

**Ids make a block revisable.** `Block::id` is stable within a reply: a producer
that declares one (a render spec's `id`) replaces that block; otherwise the id
is derived from the block itself. `upsert` is the only merge rule.

**Display policy belongs to the app.** A block says *what it is*; the shell
decides inline, card, detail screen, or nothing (a voice-only call may show no
UI at all). Prompts cannot enforce placement, and placement depends on screen
size, block size, and what is already open.

**The spoken block must stand alone.** On a call the caller hears the reply
before the rest exists, so the first `Speak` is emitted as soon as it is
complete and everything else lands after. A speak block that says "see below"
is a bug, not a layout choice.

**Fail-open, twice.** An envelope the model does not name is kept verbatim; a
block that does not validate (empty spoken text, an artifact with no ticket, a
render spec that is not a spec) also becomes `Unparsed`. A block a shell cannot
read must never lose the reply, and a shell must never try to draw garbage.

**Data, not code.** A render spec names components from the *app's* catalog
(`JSONRenderSpec.catalog`) and actions from the *app's* tool registry
(`RenderTools`), which confirms sensitive ones and audits every dispatch
(`docs/idfon-edge.md` §P5). Unknown components are dropped with their subtrees;
the agent supplies neither code nor markup. Limits: 64 KiB and 200 elements
per spec.

## Where it lives

| Piece | Path |
| --- | --- |
| The model (parse, validate, ids, upsert, encode) | `crates/idfon-protocol/src/blocks.rs` |
| Envelope splitter + `RenderEnvelope` | `ios/Idfon/Models.swift`, `mac/Sources/Idfon/Models.swift` |
| Thread rows | `ios/Idfon/ChatViewController.swift`, `mac/Sources/Idfon/ChatViewController.swift` |
| The live tree, actions, audit | `JSONRenderView`, `RenderTools`, `RenderBlockViewController` (both apps) |

**The envelope header list is duplicated on purpose and must stay in step**
(`ENVELOPE_HEADERS` in Rust, `MessageBody.prefixes` in both shells). A header one
side knows and the other does not is a block that gets cut in the wrong place.

## Status

Built: the model with tests; the `render` tool
(`integrations/eve-idfon/extension/tools/render.ts`), so a remote agent can
produce a block; the envelope end to end (parse → thread row → sheet/VC →
catalog action → audit); and the gist each row shows
(`JSONRenderSpec.summary`). The thread row shows the gist inline with the live
tree one tap away. The wire shape is pinned four ways: the TS tool's emitted
envelope is a Rust test fixture, and the shells' `MessageKindParseCheck`
asserts the same shape parses.

Open: hosting the *live* tree inline in a row (needs a height budget per row;
the chat tables size rows from their labels today); blocks that *replace* an
earlier one inside one reply — `upsert` is ready in the protocol and the id is
carried end to end, but replies arrive whole and no producer emits a revision
yet, so no shell merges; and a single render host shared by the artifact detail
screen and the block sheet, which currently repeat the confirm and result UI
(`shortcut:` noted in both).

Deliberately not a producer id: `speak`. Two speak blocks in one reply are two
utterances, not a revision, so a declared id there would silently swallow the
second one; `artifact` already derives its id from `artifact_id`.
