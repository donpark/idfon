import { defineChannel, POST } from "eve/channels";
import { parseAnswers } from "eve/client";

import extension from "../extension";
import { logger } from "../log";
import { drainEnvelopes } from "../outbox";

const log = logger("idfon.agent");

const MIME_BY_EXTENSION: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
  webp: "image/webp", pdf: "application/pdf", txt: "text/plain",
  md: "text/markdown", json: "application/json", csv: "text/csv",
  html: "text/html", svg: "image/svg+xml", wav: "audio/wav",
  mp3: "audio/mpeg", ogg: "audio/ogg", mp4: "video/mp4",
};

/// The attachment's file name, from its envelope's `name=` line.
function attachmentName(text: string): string {
  return /(?:^|\n)name=([^\n]+)/.exec(text)?.[1]?.trim() ?? "";
}

/// Media type from a file name, so an image (e.g. a screenshot) reaches the
/// model as an image, a text file as text, and neither as an opaque blob.
function mediaTypeForName(name: string): string {
  const ext = name.toLowerCase().split(".").pop() ?? "";
  return MIME_BY_EXTENSION[ext] ?? "application/octet-stream";
}

type TurnIn = {
  message_id: string;
  peer_id: string;
  endpoint_id: string;
  idempotency_key: string;
  conversation?: string;
  text: string;
  blob_ticket?: string;
  size_bytes?: number;
  a2a_depth?: number;
  capabilities?: string[];
  // Provenance for holder-injected turns (e.g. `gpt-live-delegation`).
  source?: string;
  // Correlation id from the holder, for joining agent logs to the trace.
  trace?: string;
  // Caller-pushed per-turn context (unsigned, untrusted). The UI attaches the
  // active caller-side state (e.g. per-contact speech settings) when it
  // initiates the turn; the agent sees it as a data block, never instructions.
  context?: string;
};

const MAX_CONTEXT_CHARS = 4096;

type SessionMember = {
  messageId: string;
  peerId: string;
  endpointId: string;
};

type SessionTarget = {
  conversation?: string;
  lastPeerId: string;
  turnMessageId: string;
  members: Map<string, SessionMember>;
};

const sessionTargets = new Map<string, SessionTarget>();const roomTargets = new Map<string, SessionTarget>();
// Approval interactions opened in a session, so their settlement reports as an
// authorization status rather than an input answer.
const approvals = new Set<string>();
let replyTail: Promise<void> = Promise.resolve();

function authFor(
  turn: Pick<TurnIn, "peer_id" | "endpoint_id" | "capabilities" | "source" | "context">,
) {
  return {
    authenticator: "idfon",
    principalId: turn.peer_id,
    principalType: "idfon-peer",
    attributes: {
      peer_id: turn.peer_id,
      endpoint_id: turn.endpoint_id,
      capabilities: turn.capabilities ?? [],
      // Holder-injected turns carry distinct provenance so F10/approval
      // policies can tell them from real client messages.
      ...(turn.source ? { idfon_source: turn.source } : {}),
      // Caller-pushed per-turn context, surfaced to dynamic instructions.
      ...(turn.context ? { idfon_context: turn.context.slice(0, MAX_CONTEXT_CHARS) } : {}),
    },
  };
}

async function bridge(path: string, body: unknown) {
  const response = await fetch(`${extension.config.bridgeUrl}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-idfon-channel-secret": extension.config.secret,
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`idfon bridge ${path} returned HTTP ${response.status}`);
  }
  return response;
}

async function bridgeJson<T>(path: string, body: unknown): Promise<T> {
  return (await bridge(path, body)).json() as Promise<T>;
}

async function bridgeRetry(path: string, body: unknown) {
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      return await bridge(path, body);
    } catch (error) {
      lastError = error;
      if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 100 * 2 ** attempt));
    }
  }
  throw lastError;
}

export default defineChannel({
  turnPolicy: "queue",
  audience({ caller }) {
    return caller.type === "principal" ? "private" : "unknown";
  },
  routes: [
    POST("/idfon/turn", async (request, { from, resolveSession, attachSession, waitUntil }) => {
      const secret = request.headers.get("x-idfon-channel-secret");
      if (secret !== extension.config.secret) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const turn = (await request.json()) as Partial<TurnIn>;
      if (!turn.message_id || !turn.peer_id || !turn.endpoint_id || !turn.text) {
        return Response.json({ error: "invalid turn" }, { status: 400 });
      }
      const completeTurn = turn as TurnIn;
      log.info("turn received", {
        message_id: turn.message_id, peer_id: turn.peer_id, conversation: turn.conversation,
        a2a_depth: turn.a2a_depth, source: turn.source, chars: turn.text.length,
      });
      if (completeTurn.a2a_depth !== undefined && completeTurn.a2a_depth > 1) {
        log.warn("turn ignored: a2a_loop_guard", { message_id: turn.message_id, a2a_depth: turn.a2a_depth });
        return Response.json({ ignored: true, reason: "a2a_loop_guard" });
      }
      // Session control (`IDFON-SESSION/1`): not a turn. `rotate` clears the
      // model history before a new call's first turn so the session log is never
      // treated as the model's context (docs/session-context.md).
      if (completeTurn.text.startsWith("IDFON-SESSION/1\n")) {
        const action = /(?:^|\n)action=([a-z]+)/.exec(completeTurn.text)?.[1];
        if (action === "rotate" || action === "clear") {
          const address = completeTurn.conversation || completeTurn.peer_id;
          const session = await resolveSession(address);
          if (session) await session.clear();
          return Response.json({ session: "cleared" });
        }
      }
      // A room is one Eve session shared by all senders. Keep 1:1 sessions
      // keyed by peer id, while a room session is keyed by conversation.
      const address = completeTurn.conversation || completeTurn.peer_id;
      const name = attachmentName(completeTurn.text);
      const message = completeTurn.blob_ticket
        ? [
            { type: "text" as const, text: completeTurn.text },
            {
              type: "file" as const,
              // The name rides the URL: `fetchFile` only sees the URL, and it
              // must return the same media type this part declares, or the
              // model gets an opaque blob instead of an image or text file.
              data: new URL(
                `idfon-blob:${encodeURIComponent(completeTurn.blob_ticket)}?name=${encodeURIComponent(name)}`,
              ),
              mediaType: mediaTypeForName(name),
            },
          ]
        : completeTurn.text;
      const auth = authFor(completeTurn);
      const existing = completeTurn.conversation
        ? await resolveSession(address)
        : undefined;
      let sessionId: string;
      if (existing) {
        sessionId = existing.id;
      } else {
        const session = await from(address).send(message, { auth });
        sessionId = session.sessionId;
      }
      const target = completeTurn.conversation
        ? roomTargets.get(completeTurn.conversation) ?? {
            conversation: completeTurn.conversation,
            lastPeerId: completeTurn.peer_id,
            turnMessageId: completeTurn.message_id,
            members: new Map<string, SessionMember>(),
          }
        : sessionTargets.get(sessionId) ?? {
            conversation: undefined,
            lastPeerId: completeTurn.peer_id,
            turnMessageId: completeTurn.message_id,
            members: new Map<string, SessionMember>(),
          };
      target.lastPeerId = completeTurn.peer_id;
      target.turnMessageId = completeTurn.message_id;
      target.members.set(completeTurn.peer_id, {
        messageId: completeTurn.message_id,
        peerId: completeTurn.peer_id,
        endpointId: completeTurn.endpoint_id,
      });
      sessionTargets.set(sessionId, target);
      if (completeTurn.conversation) {
        roomTargets.set(completeTurn.conversation, target);
        await bridge("/room/member", {
          conversation: completeTurn.conversation,
          peer_id: completeTurn.peer_id,
          endpoint_id: completeTurn.endpoint_id,
          message_id: completeTurn.message_id,
        });
      }
      if (existing) {
        waitUntil(
          attachSession(existing.id).send(message, { auth }).catch((error) =>
            log.error("room turn failed", { error: String(error), message_id: completeTurn.message_id })
          )
        );
      }
      return Response.json({ sessionId, address });
    }),
    POST("/idfon/status", async (request) => {
      const secret = request.headers.get("x-idfon-channel-secret");
      if (secret !== extension.config.secret) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const status = (await request.json()) as {
        peer_id?: string;
        endpoint_id?: string;
        event?: string;
        data?: unknown;
      };
      if (!status.peer_id || !status.endpoint_id || !status.event || status.data === undefined) {
        return Response.json({ error: "invalid status" }, { status: 400 });
      }
      return Response.json({ event: status.event });
    }),
    POST("/idfon/input", async (request, { from }) => {
      const secret = request.headers.get("x-idfon-channel-secret");
      if (secret !== extension.config.secret) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const input = (await request.json()) as {
        peer_id?: string;
        endpoint_id?: string;
        conversation?: string;
        responses?: unknown;
        capabilities?: string[];
      };
      if (!input.peer_id || !input.endpoint_id || input.responses === undefined) {
        return Response.json({ error: "invalid input response" }, { status: 400 });
      }
      let responses;
      try {
        responses = parseAnswers(input.responses);
      } catch {
        return Response.json({ error: "invalid input responses" }, { status: 400 });
      }
      const address = input.conversation
        ? `${input.peer_id}:${input.conversation}`
        : input.peer_id;
      await from(address).respond(responses, {
        auth: authFor({
          peer_id: input.peer_id,
          endpoint_id: input.endpoint_id,
          capabilities: input.capabilities,
        }),
      });
      return Response.json({ address });
    }),
  ],
  async fetchFile(url) {
    if (!url.startsWith("idfon-blob:")) return null;
    const parsed = new URL(url);
    const ticket = decodeURIComponent(parsed.pathname);
    const response = await bridge("/blob", { ticket });
    const result = (await response.json()) as { bytes_base64: string };
    return {
      bytes: Buffer.from(result.bytes_base64, "base64"),
      mediaType: mediaTypeForName(parsed.searchParams.get("name") ?? ""),
    };
  },
  events: {
    // Realtime forwarding (P4): agent output deltas reach the holder over the
    // loopback bridge so TTS can start before the turn completes. Reasoning is
    // never forwarded. Eve 1.0 renamed `message.appended` to `content.delta`;
    // the holder still dedupes on (turnId, stepIndex, sequence), so the
    // stream position supplies those and the hop stays retry-safe.
    async "content.delta"(event, ctx) {
      if (event.data.kind === "reasoning") return;
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/stream/append", {
        peer_id: member.peerId,
        turn_id: event.scope?.turnId ?? ctx.session.turn.id,
        step_index: ctx.position.line,
        sequence: ctx.position.index,
        text: event.data.delta,
      });
    },
    async "content.completed"(event, ctx) {
      // One reply part, not the whole turn (Eve 1.0 splits text by phase).
      if (event.data.kind !== "text" || event.data.phase !== "reply") return;
      const message = typeof event.data.value === "string" ? event.data.value : "";
      const target = sessionTargets.get(ctx.session.id);
      if (!target || !message) {
        // A dropped reply is invisible otherwise: the caller just hears silence.
        log.warn("reply dropped: no session target", {
          session: ctx.session.id, has_message: !!message,
        });
        return;
      }
      // Client-facing envelopes emitted by tools (speak/point/show) ride the
      // reply in tool-call order, so delivery never depends on the model
      // echoing them (docs/voice-multimodal.md).
      const emitted = drainEnvelopes(ctx.session.id);
      const text = emitted.length ? `${message}\n${emitted.join("\n")}` : message;
      const roomMembers = target.conversation
        ? new Map(
            (await bridgeJson<{ members: Array<{ message_id: string; peer_id: string; endpoint_id: string }> }>(
              "/room/members",
              { conversation: target.conversation }
            )).members.map((member) => [member.peer_id, {
              messageId: member.message_id,
              peerId: member.peer_id,
              endpointId: member.endpoint_id,
            }] as const)
          )
        : target.members;
      if (roomMembers.size === 0) {
        log.warn("reply dropped: no members", {
          session: ctx.session.id, conversation: target.conversation, turn: target.turnMessageId,
        });
      }
      const delivery = replyTail.then(async () => {
        for (const member of roomMembers.values()) {
          await bridgeRetry("/reply", {
            // The holder uses this as the IPC correlation key. Add the recipient
            // so fan-out replies from one Eve turn cannot collide.
            in_reply_to: `${member.messageId}|${target.turnMessageId}|${member.peerId}`,
            peer_id: member.peerId,
            endpoint_id: member.endpointId,
            conversation: target.conversation,
            text,
          });
        }
      });
      replyTail = delivery.catch(() => {});
      await delivery;
    },
    async "interaction.opened"(event, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      const { interactionId, request } = event.data;
      if (request.kind === "approval") {
        // Kept apart from input requests so `interaction.settled` can report
        // an authorization result and a question answer through its own path.
        approvals.add(interactionId);
        await bridge("/status", {
          in_reply_to: member.messageId,
          event: "authorization.required",
          data: event.data,
        });
        return;
      }
      // The holder's HITL card keys off `requestId`; the new interaction
      // fields (kind, prompt, options) ride along for its renderer.
      await bridge("/input", {
        request_id: interactionId,
        peer_id: member.peerId,
        endpoint_id: member.endpointId,
        conversation: target?.conversation,
        requests: [{ requestId: interactionId, ...request }],
      });
    },
    async "interaction.settled"(event, ctx) {
      if (!approvals.delete(event.data.interactionId)) return;
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: "authorization.completed",
        data: event.data,
      });
    },
    async "turn.settled"(event, ctx) {
      // A settled error/cancel ends the turn: emitted envelopes must not leak
      // into a later one, and the holder shows the same status names it did
      // before Eve 1.0 folded both into `turn.settled`.
      if (event.data.outcome === "completed") return;
      drainEnvelopes(ctx.session.id);
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: event.data.outcome === "cancelled" ? "turn.cancelled" : "turn.failed",
        data: event.data,
      });
    },
  },
});
