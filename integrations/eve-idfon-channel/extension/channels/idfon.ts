import { defineChannel, POST } from "eve/channels";
import { parseInputResponses } from "eve/client";

import extension from "../extension";

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
};

type SessionMember = {
  messageId: string;
  peerId: string;
  endpointId: string;
};

type SessionTarget = {
  conversation?: string;
  lastPeerId: string;
  members: Map<string, SessionMember>;
};

const sessionTargets = new Map<string, SessionTarget>();

function authFor(turn: Pick<TurnIn, "peer_id" | "endpoint_id" | "capabilities">) {
  return {
    authenticator: "idfon",
    principalId: turn.peer_id,
    principalType: "idfon-peer",
    attributes: {
      peer_id: turn.peer_id,
      endpoint_id: turn.endpoint_id,
      capabilities: turn.capabilities ?? [],
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

export default defineChannel({
  turnPolicy: "queue",
  audience({ auth }) {
    return auth ? "private" : "unknown";
  },
  routes: [
    POST("/idfon/turn", async (request, { from }) => {
      const secret = request.headers.get("x-idfon-channel-secret");
      if (secret !== extension.config.secret) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const turn = (await request.json()) as Partial<TurnIn>;
      if (!turn.message_id || !turn.peer_id || !turn.endpoint_id || !turn.text) {
        return Response.json({ error: "invalid turn" }, { status: 400 });
      }
      const completeTurn = turn as TurnIn;
      if (completeTurn.a2a_depth !== undefined && completeTurn.a2a_depth > 1) {
        return Response.json({ ignored: true, reason: "a2a_loop_guard" });
      }
      // A room is one Eve session shared by all senders. Keep 1:1 sessions
      // keyed by peer id, while a room session is keyed by conversation.
      const address = completeTurn.conversation || completeTurn.peer_id;
      const message = completeTurn.blob_ticket
        ? [
            { type: "text" as const, text: completeTurn.text },
            {
              type: "file" as const,
              data: new URL(`idfon-blob:${encodeURIComponent(completeTurn.blob_ticket)}`),
              mediaType: "application/octet-stream",
            },
          ]
        : completeTurn.text;
      const session = await from(address).send(message, {
        auth: authFor(completeTurn),
      });
      const target = sessionTargets.get(session.id) ?? {
        conversation: completeTurn.conversation,
        lastPeerId: completeTurn.peer_id,
        members: new Map<string, SessionMember>(),
      };
      target.lastPeerId = completeTurn.peer_id;
      target.members.set(completeTurn.peer_id, {
        messageId: completeTurn.message_id,
        peerId: completeTurn.peer_id,
        endpointId: completeTurn.endpoint_id,
      });
      sessionTargets.set(session.id, target);
      return Response.json({ sessionId: session.id, address });
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
        responses = parseInputResponses(input.responses);
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
    const ticket = decodeURIComponent(url.slice("idfon-blob:".length));
    const response = await bridge("/blob", { ticket });
    const result = (await response.json()) as { bytes_base64: string };
    return {
      bytes: Buffer.from(result.bytes_base64, "base64"),
      mediaType: "application/octet-stream",
    };
  },
  events: {
    async "message.completed"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      if (!target || !event.message) return;
      await Promise.all([...target.members.values()].map((member) =>
        bridge("/reply", {
          in_reply_to: member.messageId,
          peer_id: member.peerId,
          endpoint_id: member.endpointId,
          conversation: target.conversation,
          text: event.message,
        })
      ));
    },
    async "input.requested"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      const request = event.requests[0];
      if (!member || !request) return;
      await bridge("/input", {
        request_id: request.requestId,
        peer_id: member.peerId,
        endpoint_id: member.endpointId,
        conversation: target?.conversation,
        requests: event.requests,
      });
    },
    async "authorization.required"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: "authorization.required",
        data: event,
      });
    },
    async "authorization.completed"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: "authorization.completed",
        data: event,
      });
    },
    async "turn.cancelled"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: "turn.cancelled",
        data: event,
      });
    },
    async "turn.failed"(event, _channel, ctx) {
      const target = sessionTargets.get(ctx.session.id);
      const member = target?.members.get(target.lastPeerId);
      if (!member) return;
      await bridge("/status", {
        in_reply_to: member.messageId,
        event: "turn.failed",
        data: event,
      });
    },
  },
});
