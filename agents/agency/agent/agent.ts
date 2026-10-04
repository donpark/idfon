import { defineAgent } from "eve";

// Bootstrap agent: the caller reaches this one contact to discover and get
// invited to the other agents. It does not serve a model of its own; its job
// is to resolve a request ("I want to talk to GPT-6.1-Sol") into a contact
// invite via the `request-invite` tool.
const model = process.env.EVE_IDFON_MODEL || "openai/gpt-6-luna";

export default defineAgent({ model });
