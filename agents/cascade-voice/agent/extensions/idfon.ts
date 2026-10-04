import idfon from "eve-idfon";

// Cascade demo: no `live` block. The holder advertises `client-cascade`
// (agents/cascade-voice/live.json) and never intercepts live media; the app's
// on-device STT/TTS drives the conversation.
export default idfon({
  bridgeUrl: "http://127.0.0.1:18766",
  secret: "m2-test-secret",
});
