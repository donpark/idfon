import idfon from "eve-idfon";

// Generic voice agent: no `live` block. The holder's live config
// (live.json / providers/*.json) selects the voice backend and provider; this
// agent only handles the resulting text.
export default idfon({
  bridgeUrl: process.env.IDFON_BRIDGE_URL ?? "http://127.0.0.1:18766",
  secret: process.env.IDFON_BRIDGE_SECRET ?? "m2-test-secret",
});
