import { defineChannel, POST } from "eve/channels";

import extension from "../extension";

type TurnIn = {
  message_id: string;
  peer_id: string;
  endpoint_id: string;
  idempotency_key: string;
  conversation?: string;
  text: string;
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
      const session = await from(address).send(completeTurn.text, {
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
