import idfon from "eve-idfon";

export default idfon({
  bridgeUrl: process.env.IDFON_BRIDGE_URL ?? "http://127.0.0.1:18766",
  secret: process.env.IDFON_BRIDGE_SECRET ?? "m2-test-secret",
  // Agent-specific live-call metadata. Mirrors agents/gpt-live-1/live.json,
  // which the serve script forwards to the holder's live-call handler
  // (`serve --live-config`); the platform never reads these values.
  //
  // This `live` block opts the holder into the GPT-Live-1 full-duplex backend
  // (one engine a voice agent can run; see docs/voice-agent.md). Copy it to
  // another agent only when that agent really should run GPT-Live.
  live: {
    live_url: "wss://ai-gateway.vercel.sh/v1/live/sessions",
    model: "openai/gpt-live-1",
    api_key_env: "AI_GATEWAY_API_KEY",
    broadcast: "idfon-live-agent",
    source: "gpt-live-delegation",
    reply_max_seconds: 120,
  },
});
