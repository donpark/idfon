import { appendFileSync } from "node:fs";
import { defineChannel, POST } from "eve/channels";

const replyFile = process.env.EVE_SPIKE_REPLY_FILE ?? "/tmp/eve-channel-spike-replies.ndjson";

const authFor = (peerId: string) => ({
  authenticator: "idfon-spike",
  principalId: peerId,
  principalType: "idfon-peer",
  attributes: { peer_id: peerId },
});

export default defineChannel({
  turnPolicy: "queue",
  routes: [
    POST("/idfon/turn", async (request, { from }) => {
      const body = (await request.json()) as {
        peerId?: string;
        conversation?: string;
        text?: string;
      };
      if (!body.peerId || !body.text) {
        return Response.json({ error: "peerId and text are required" }, { status: 400 });
      }

      const address = body.conversation
        ? `${body.peerId}:${body.conversation}`
        : body.peerId;
      const session = await from(address).send(body.text, {
        auth: authFor(body.peerId),
      });
      return Response.json({ sessionId: session.id, address });
    }),
  ],
  events: {
    "message.completed"(event, _channel, ctx) {
      appendFileSync(
        replyFile,
        `${JSON.stringify({
          sessionId: ctx.session.id,
          message: event.message,
          principalId: ctx.session.auth.initiator?.principalId ?? null,
        })}\n`,
      );
    },
  },
});
