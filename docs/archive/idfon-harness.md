## idfon app agent harness

If your proxy is strictly maintaining a 1:1, low-latency audio stream between a client and OpenAI's `gpt-live-1` (or Realtime API), **you do not need an agent loop inside the voice connection path itself**.

However, introducing an **Agent Loop** (or using [Eve](https://github.com/vercel/eve)'s task loop engine) becomes essential the moment your assistant needs to do **asynchronous, multi-step backend work without blocking the voice stream**.

---

### Why a Passthrough Proxy Isn't Enough (When Voice Meets Real Work)

With full-duplex models like `gpt-live-1`, the voice layer handles real-time speech, interruptions, and turn-taking directly via WebRTC or WebSockets. If the user asks something simple, the model answers instantly.

An agent loop becomes necessary for three main capabilities:

#### 1. Offloading Multi-Step Reasoning & Tools (Delegation)

* **The Problem:** Audio connections demand strict, low-latency execution (<500ms). If a user asks, *"Check my calendar, draft a summary email, and post a message to Slack,"* forcing the voice model to run sequential tool calls in real-time creates awkward long silences and risks connection timeouts.
* **The Agent Loop Solution:** When the voice session detects a complex request, it delegates the task off-stream to a backend agent loop. The loop handles the heavy lifting—running multi-step tools, evaluating conditions, and querying databases—while the voice session stays alive, providing smooth filler speech (*"I'm looking into that now..."*) until the loop completes.

#### 2. Durability and State Recovery (Durable Execution)

* **The Problem:** Realtime WebSockets and WebRTC connections drop frequently (e.g., a mobile client switches from Wi-Fi to cellular). If state lives purely in the active proxy/voice socket, a dropped call destroys the task context.
* **The Agent Loop Solution:** Frameworks like [Eve](https://github.com/vercel/eve) persist the agent's task state, execution history, and memory onto disk/database decoupled from the socket layer. If the voice channel disconnects, the background agent loop continues running, and the user can reconnect seamlessly without starting over.

#### 3. Human-In-The-Loop (HITL) & Verification Gates

* **The Problem:** If a tool call has critical real-world impact (e.g., transferring funds, deleting files, sending an email), you cannot rely solely on instant, probabilistic voice generation.
* **The Agent Loop Solution:** An agent loop provides structured control flow (e.g., `pause -> await approval -> proceed`). It allows the backend to pause execution, prompt the user via voice or app UI for explicit confirmation, and resume safely once approved.

---

### Architectural Pattern: Voice Session vs. Agent Loop

The recommended pattern decouples the real-time interaction layer from the action execution layer:

```
[ Client ] 
   │  ▲  (Real-Time Audio Stream)
   ▼  │
┌─────────────────────────┐         Delegates Task         ┌─────────────────────────┐
│ Eve Voice Proxy         │ ─────────────────────────────> │ Background Agent Loop   │
│ (gpt-live-1 Session)    │                                │ (Eve Engine / Workflows)│
└─────────────────────────┘ <───────────────────────────── └─────────────────────────┘
  • High speed / Full-duplex  Task Status & Final Results   • Multi-step execution
  • Generates filler speech                                 • Tool calls & DB writes
  • Handles interruptions                                  • Durable state & HITL

```

---

### When Do You *NOT* Need an Agent Loop?

You can stick to a simple proxy without an agent loop if:

* Your assistant is purely conversational (e.g., language practice, voice Q&A, mock interviewing).
* All tools are fast, single-turn read-only lookups (e.g., `get_current_weather` or `check_time`) where execution finishes in <1 second.
* You don't need persistent workflow execution across client reconnections.

===

In the context of Vercel’s **Eve** framework, an **Eve agent** is a filesystem-first workspace designed around durable execution via Vercel Workflows.

When combining Eve with a real-time voice protocol like `openai/gpt-live-1` (via Vercel AI Gateway), the Eve agent acts as the **async background execution loop**. This design prevents long-running tasks from stalling the low-latency audio stream or timing out during a disconnect.

---

### How the Architecture Looks

Instead of putting all business logic directly into the real-time voice proxy, you split your architecture into two components:

```
[ Client App / Browser ] 
       │
       │ (1) Low-latency WebSocket / Full-Duplex Audio
       ▼
┌─────────────────────────────────────────────────────────┐
│ Eve Voice Proxy (gpt-live-1 Session)                    │
│ • Maintains continuous audio stream                     │
│ • Handles interruptions & filler speech                 │
│ • Emits / listens for delegation events                 │
└──────────────────────────┬──────────────────────────────┘
                           │
                           │ (2) Asynchronously triggers delegate task
                           ▼
┌─────────────────────────────────────────────────────────┐
│ Eve Agent Loop (Vercel Workflows Runtime)               │
│ └── agent/                                              │
│     ├── instructions.md (System behavior & context)     │
│     ├── tools/          (Typed TS execution tools)     │
│     ├── skills/         (On-demand markdown playbooks)  │
│     └── agent.ts        (Model and runtime config)      │
└──────────────────────────┬──────────────────────────────┘
                           │
                           │ (3) Emits state updates back to session
                           ▼
                 [ Voice Proxy Context Append ]

```

---

### Step-by-Step Execution Flow

1. **Voice Session Stays Fast:** The user interacts with `gpt-live-1` via the audio stream.
2. **Delegation Event:** When the user asks for a complex action (e.g., *"Reconcile my monthly expenses and notify Slack"*), `gpt-live-1` issues a **Client Delegation event** to your Eve voice proxy.
3. **Voice Filler Speech:** The voice proxy responds to the user immediately (*"I'm on it, starting that reconciliation in the background..."*) so there is no awkward silence on the call.
4. **Eve Agent Loop Runs:** The proxy triggers an **Eve agent task run**. Eve picks up the request and executes its file-based agent workflow:
* Executes tools in `agent/tools/*.ts` (e.g., database queries, API calls).
* Pulls in dynamic playbooks from `agent/skills/*.md` if sub-reasoning is needed.
* If a human approval step is required (e.g., `needsApproval: true`), the Eve workflow safely **parks its state** using Vercel's durable execution engine until confirmed.


5. **Context Syncing:** Once the background Eve loop finishes (or reaches a landmark step), it pushes a context update back to the voice proxy session. `gpt-live-1` then announces the completed result to the user naturally.

---

### What the Code/Filesystem Structure Looks Like

In an Eve project, the background agent is configured directly in the codebase as structured files:

```text
my-voice-assistant/
├── app/
│   └── api/
│       └── live-token/route.ts      # Mints tokens for gpt-live-1 WebSocket
└── agent/                           # The Eve Agent Loop
    ├── instructions.md              # Long-running system prompt & guardrails
    ├── agent.ts                     # Runtime config & model settings
    ├── tools/
    │   ├── search_database.ts       # Typed execution functions
    │   └── execute_transaction.ts
    └── skills/
        └── financial_audit.md       # On-demand procedures

```

#### 1. Defining a Durable Tool (`agent/tools/execute_transaction.ts`)

Eve allows you to mark high-impact actions for approval. The state persists even if the voice connection drops mid-call.

```typescript
import { defineTool } from "eve/tools";
import { z } from "zod";

export default defineTool({
  description: "Execute a financial transaction on behalf of the user",
  needsApproval: true, // Parks the Eve Workflow loop until approved
  inputSchema: z.object({
    amount: z.number(),
    recipient: z.string(),
  }),
  async execute({ amount, recipient }) {
    // Business logic runs safely in sandboxed compute
    const result = await db.transactions.create({ amount, recipient });
    return { status: "success", txId: result.id };
  },
});

```

#### 2. Delegating from the Live Voice Handler (`app/api/voice/delegate/route.ts`)

When `gpt-live-1` emits a delegation event, the proxy invokes Eve's durable background run:

```typescript
import { runAgent } from "eve";

export async function POST(req: Request) {
  const { taskDescription, sessionId } = await req.json();

  // Start an async Eve agent run off the main audio thread
  const run = await runAgent({
    agentDir: "./agent",
    input: taskDescription,
    metadata: { sessionId },
  });

  // Return immediately to keep the voice stream active
  return Response.json({ runId: run.id, status: "queued" });
}

```

---

### Why This Hybrid Pattern Works Best

* **Low Latency Audio:** `gpt-live-1` never hangs waiting for long database queries or third-party APIs.
* **Resilience:** If the user loses mobile connection mid-conversation, the Eve agent loop finishes its work safely on Vercel infrastructure.
* **Safety:** High-risk actions can pause for human approval via web/SMS UI without breaking the audio WebSocket connection.
