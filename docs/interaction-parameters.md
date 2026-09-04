# Interaction Parameters

## Status

Design proposal.

## Summary

Idfon separates the standalone CLI from the GUI. The CLI provides a narrow,
agent-to-agent communication surface. The GUI owns interaction policy because
policy is primarily about local UX: attention, notification, interruption,
playback, recording, scheduling, and user control.

Interaction behavior is represented as a validated set of parameters. A formal
specification or a free-form design prompt may be used to produce those
parameters, but neither becomes executable behavior by itself.

```text
formal spec or design prompt
          ↓
GUI parameter editor / generator
          ↓
validation and user approval
          ↓
local UX policy
          ↓
CLI / agent protocol for transport-level operations
```

The runtime should execute typed, approved parameters—not arbitrary natural
language and not a general-purpose workflow language.

## Goals

- Keep the CLI standalone and focused on agent-to-agent communication.
- Keep UX-specific policy in the GUI and under local user control.
- Represent interaction behavior with simple, inspectable key/value parameters.
- Allow parameters to be authored manually or generated from a design prompt.
- Validate parameters before they affect communication or media behavior.
- Make transport, interaction intent, media, UX, and authorization concerns
  distinguishable.
- Allow the GUI to preview and explain the resulting behavior.
- Support versioning and migration of parameter sets.

## Non-goals

- Making the CLI a GUI-policy engine.
- Executing free-form prompts directly.
- Defining a general workflow or programming language.
- Embedding JavaScript, Python, shell commands, or arbitrary code in a spec.
- Replacing the agent-to-agent protocol with GUI-specific commands.
- Automatically granting permissions because a parameter was generated.

## Responsibility boundaries

### Standalone CLI / agent runtime

The CLI is responsible for narrow agent-to-agent operations:

- identity and endpoint management;
- peer and ticket handling;
- connecting to another agent;
- sending requests or messages;
- receiving requests or messages;
- request identifiers, timeouts, and structured errors;
- protocol-level capability and expiration metadata;
- machine-readable output and event streams.

The CLI should not decide whether an incoming message interrupts a user,
plays automatically, displays a notification, or is recorded.

### GUI

The GUI is responsible for local interaction policy:

- whether an authorized interaction is accepted;
- whether the user is interrupted;
- notification style and timing;
- queueing and playback behavior;
- availability schedules;
- local mute and volume behavior;
- recording and retention choices;
- policy editing, preview, approval, and revocation;
- visible active-state indicators and emergency stop.

The GUI may use the standalone CLI as its transport or agent integration, but
it should not depend on CLI implementation details to render policy.

### Transport and media implementations

Iroh, QUIC, `iroh-live`, and `iroh-blobs` implement delivery mechanisms. They
should not define Idfon policy or UX behavior. A parameter set may select a
logical interaction mode, while the implementation chooses the appropriate
transport and media path.

## Parameter model

A parameter set is a versioned collection of names and values. Values should
be typed even when the serialized representation is JSON or YAML.

```yaml
version: 1
interaction:
  mode: live_audio
  delivery: immediate
  notify: true
  auto_accept: false
  interrupt: false
  record: false
  expires_at: 2026-12-31T18:00:00Z
```

The parameter set describes intent and policy. It does not describe stream
creation, ALPN negotiation, byte framing, or other transport mechanics.

### Namespaces

Namespaces make ownership explicit:

```yaml
transport:
  peer: bob
  method: live_audio.invite
  timeout_ms: 10000

interaction:
  mode: live_audio
  delivery: immediate

media:
  codec: opus
  sample_rate: 48000

ux:
  notify: true
  auto_accept: false
  interrupt: false
  volume: 80

policy:
  capability: live_audio
  record: false
  expires_at: 2026-12-31T18:00:00Z
```

The initial implementation should use a small allowlist of supported
parameters. Unknown parameters should produce a validation warning or error;
they should never silently alter behavior.

### Initial parameter vocabulary

The first version can support:

| Parameter | Values | Owner |
|---|---|---|
| `interaction.mode` | `text`, `voice_message`, `live_audio` | GUI / protocol |
| `interaction.delivery` | `immediate`, `queue`, `manual` | GUI |
| `interaction.notify` | boolean or notification policy | GUI |
| `interaction.auto_accept` | boolean | GUI |
| `interaction.interrupt` | boolean | GUI |
| `interaction.record` | boolean | GUI / policy |
| `interaction.schedule` | named or bounded time window | GUI / policy |
| `policy.capability` | capability name | policy |
| `policy.expires_at` | timestamp | policy |
| `policy.retention` | duration or `none` | GUI / policy |
| `transport.peer` | configured peer name or identity | CLI / protocol |
| `transport.method` | registered protocol method | CLI / protocol |
| `media.codec` | supported codec | media |
| `media.volume` | bounded numeric value | GUI |

This vocabulary is intentionally small. New parameters should be added only
when a real UX or protocol requirement exists.

## Local policy evaluation

An incoming operation is evaluated in stages:

```text
incoming transport event
  → identify peer and operation
  → verify protocol and message limits
  → check capability grant
  → load applicable GUI parameters
  → evaluate schedule and current local state
  → choose accept / notify / queue / play / reject
  → update visible state and audit event
```

Authorization and UX are separate decisions. A peer may be authorized to send
live audio while the local policy chooses to notify first or queue it.

Example:

```yaml
interaction:
  mode: live_audio
  auto_accept: false
  notify: prominent
  interrupt: false

policy:
  capability: live_audio
  expires_at: 2026-12-31T18:00:00Z
```

This means the peer may attempt live audio, but the GUI does not automatically
play it or interrupt an existing interaction.

Policy evaluation should fail closed:

- unknown peer: reject;
- missing capability: reject;
- expired capability: reject;
- invalid parameter combination: reject or require approval;
- unavailable device: show an error and preserve user control;
- emergency stop: override active media immediately.

## Free-form design prompts

A free-form description is an authoring aid, not a runtime format.

Example prompt:

> Let trusted contacts send live audio during work hours, but do not interrupt
> an existing conversation. Queue voice messages silently and retain them for
> one week.

Candidate parameters:

```yaml
version: 1
interaction:
  allowed_modes: [live_audio, voice_message]
  schedule: work_hours
  voice_message_delivery: queue
  voice_message_notify: silent

ux:
  interrupt: false

policy:
  trusted_contacts_only: true
  retention: 7d
```

The GUI should show the generated candidate before installation, including:

- interpreted parameters;
- assumptions made by the generator;
- unsupported or ambiguous requirements;
- requested capabilities;
- affected peers or groups;
- possible side effects;
- conflicts with existing policy.

The user must approve the result. Editing or accepting a generated parameter
set should be an explicit action.

## Formal specification input

A formal input format may be YAML or JSON. YAML is convenient for editing;
canonical JSON is useful for storage, comparison, and protocol exchange.

```text
authored YAML or form fields
  → parsed typed model
  → normalized canonical representation
  → schema validation
  → policy conflict checks
  → approval and persistence
```

The canonical representation should include:

- schema version;
- stable parameter names;
- normalized timestamps and durations;
- explicit defaults where needed;
- source metadata, such as `manual` or `prompt-generated`;
- approval time and policy revision.

The source prompt does not need to be retained if privacy makes that
undesirable, but the resulting parameters and approval history should be
inspectable.

## Validation

Validation has three levels.

### Shape validation

Checks that the input is structurally valid:

- recognized namespaces;
- recognized parameter names;
- correct value types;
- valid timestamps, durations, and enums;
- bounded numeric values.

### Semantic validation

Checks that parameters make sense together:

- `auto_accept` is meaningful for an applicable interaction mode;
- `volume` is only used with audio;
- `retention` is not enabled without recording permission;
- schedules have valid time zones and ranges;
- expiration is later than activation;
- a peer is known to the selected identity.

### Authorization validation

Checks whether the requested behavior is allowed:

- capability exists and is granted;
- the peer is trusted for that capability;
- the grant has not expired or been revoked;
- local emergency-stop and safety rules are respected;
- the requested action is within rate and resource limits.

Validation should return structured diagnostics, not only a single error string.

```json
{
  "path": "policy.retention",
  "code": "recording_not_allowed",
  "severity": "error",
  "message": "Retention requires recording permission."
}
```

## Protocol representation

The CLI/agent protocol should carry only the parameters needed by the remote
agent to understand an operation and apply its own policy.

Example invite:

```json
{
  "id": "request-123",
  "method": "live_audio.invite",
  "params": {
    "ticket": "...",
    "sender": "alice",
    "capability": "live_audio",
    "expires_at": "2026-12-31T18:00:00Z"
  }
}
```

The sender's GUI parameters such as local volume, notification style, and
whether the receiver should interrupt are not authoritative for the receiver.
The receiving GUI evaluates its own local policy.

A remote parameter may express intent, but it must not override local policy.

## Persistence and revisions

Parameter sets should be stored per identity, peer or group, capability, and
interaction context. They should have a revision number so changes can be
reverted and conflicts can be identified.

```text
identity
  └─ peer or group
      └─ interaction context
          └─ policy revision
```

The current Idfon prototype keeps connections and much of its state in memory.
Production implementation will need persistent policy storage separate from
transient endpoint and media state.

Policy persistence should support:

- atomic updates;
- explicit revocation;
- expiration without requiring peer cooperation;
- migration between schema versions;
- export for backup or inspection;
- deletion of sensitive history and generated prompts.

## GUI design implications

The GUI should present policy as understandable controls rather than raw
transport settings. Advanced users may inspect or edit the underlying
parameter set, but the normal path should use constrained controls.

Useful surfaces include:

- per-peer interaction policy;
- capability and expiration controls;
- schedule editor;
- notification and interruption controls;
- recording and retention controls;
- generated-parameter review;
- dry-run or preview of incoming interactions;
- active interaction indicator;
- immediate emergency stop;
- policy revision and revoke actions.

The GUI should make the distinction visible between:

```text
allowed to attempt
currently accepted
currently active
being recorded
```

## Testing strategy

The parameter system should be testable without Iroh, media devices, or a GUI.

Minimum tests:

- parse and normalize a valid parameter set;
- reject unknown or incorrectly typed parameters;
- reject invalid combinations;
- enforce expired and revoked capabilities;
- apply schedule boundaries;
- verify local policy overrides remote intent;
- produce deterministic dry-run decisions;
- verify emergency stop overrides active behavior;
- migrate an older parameter version.

A dry-run input can be represented as:

```json
{
  "event": "live_audio.invite",
  "peer": "alice",
  "capability": "live_audio",
  "time": "2026-06-15T10:00:00Z",
  "current_state": "conversation_active"
}
```

The result should state the decision and why:

```json
{
  "decision": "notify",
  "matched_policy": "peer-alice-live-audio",
  "reasons": [
    "capability granted",
    "within schedule",
    "auto_accept=false",
    "interrupt=false"
  ]
}
```

## Implementation path

1. Define the initial typed parameter schema and ownership rules.
2. Add a pure parser, normalizer, and validator.
3. Add policy evaluation and dry-run support without transport or media.
4. Persist policy per identity and peer/context.
5. Integrate GUI controls and visible policy decisions.
6. Add prompt-to-parameter generation as a reviewable GUI workflow.
7. Extend the standalone CLI protocol only with transport-relevant fields.
8. Add media parameters after capability and local-policy checks are enforced.

## Open questions

- Which parameters are globally scoped versus peer- or context-specific?
- Should free-form prompt generation run locally, through a configured model, or
  both?
- How much of a generated prompt and its assumptions should be persisted?
- Should policy changes apply immediately to active interactions?
- What is the minimum audit history required for recording and live audio?
- Which parameter values must be negotiated with a peer versus evaluated only
  locally?

## Decision

Idfon should treat interaction behavior as GUI-owned, validated parameter
sets. The standalone CLI should remain a narrow agent-to-agent communication
tool. Formal specifications and free-form descriptions are inputs to the GUI
policy authoring flow; only approved, validated parameters may affect local
UX or authorize an operation.
