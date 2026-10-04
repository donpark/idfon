import idfon from "eve-idfon";

// Generic voice agent: no `live` block. The holder's live config
// (live.json / providers/*.json) selects the voice backend and provider; this
// agent only handles the resulting text.
export default idfon({
  bridgeUrl: "http://127.0.0.1:18766",
  secret: "m2-test-secret",
});
