import { defineAgent } from "eve";

// radio-world: the OPML menu contact as one agent (docs/live-radio.md "The
// radio-world agent"). The station catalogue arrives as a json-render menu
// (the radio-menu tool); a pick dials the call that plays it and hanging up
// stops it. Programming — what plays when — is this agent's own tool surface
// (radio-program wraps the deterministic planner), so nobody assembles
// scripts by hand.
//
// EVE_IDFON_MODEL selects the model per serve instance, so the same agent can
// run several contacts with separate identities.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
