import idfon from "eve-idfon";

export default idfon({
  bridgeUrl: process.env.IDFON_BRIDGE_URL ?? "http://127.0.0.1:18766",
  secret: process.env.IDFON_BRIDGE_SECRET ?? "m2-test-secret",
});
