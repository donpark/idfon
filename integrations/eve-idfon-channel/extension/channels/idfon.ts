import { defineChannel, POST } from "eve/channels";

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
};

type SessionTarget = {
  messageId: string;
  peerId: string;
  endpointId: string;
  conversation?: string;
};

const sessionTargets = new Map<string, SessionTarget>();

function authFor(turn: TurnIn) {
  return {
    authenticator: "idfon",
    principalId: turn.peer_id,
    principalType: "idfon-peer",
    attributes: {
      peer_id: turn.peer_id,
      endpoint_id: turn.endpoint_id,
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
      const address = completeTurn.conversation
        ? `${completeTurn.peer_id}:${completeTurn.conversation}`
        : completeTurn.peer_id;
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
      sessionTargets.set(session.id, {
        messageId: completeTurn.message_id,
        peerId: completeTurn.peer_id,
        endpointId: completeTurn.endpoint_id,
        conversation: completeTurn.conversation,
      });
      return Response.json({ sessionId: session.id, address });
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
      if (!target || event.message == null) return;
      await bridge("/reply", {
        in_reply_to: target.messageId,
        peer_id: target.peerId,
        endpoint_id: target.endpointId,
        conversation: target.conversation,
        text: event.message,
      });
    },
  },
});
