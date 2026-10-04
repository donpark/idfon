import idfon from "eve-idfon";

export default idfon({
  bridgeUrl: "http://127.0.0.1:18766",
  secret: "m2-test-secret",
  // Agent-specific live-call metadata. Mirrors agents/live-voice/live.json,
  // which the serve script forwards to the holder's live-call handler
  // (`serve --live-config`); the platform never reads these values.
  //
  // GPT-Live-1 DEPRECATED (migration target). Do not copy this `live` block
  // into other agents: it opts the holder into the deprecated audio-only
  // handler. Live calls move to the idfon-voice cascade (STT -> agent -> TTS).
  live: {
    live_url: "wss://ai-gateway.vercel.sh/v1/live/sessions",
    model: "openai/gpt-live-1",
    api_key_env: "AI_GATEWAY_API_KEY",
    broadcast: "idfon-live-agent",
    source: "gpt-live-delegation",
    reply_max_seconds: 120,
  },
});
