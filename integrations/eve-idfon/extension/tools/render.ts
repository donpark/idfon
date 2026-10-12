import { defineTool } from "eve/tools";
import { z } from "zod";

import { emitEnvelope } from "../outbox";

// Render a declarative view for the caller. The app draws it from its own
// component catalog and resolves any action against its own tool registry, so
// the spec is data only: no code, no markup, no scripts
// (crates/idfon-protocol/src/blocks.rs, docs/reply-blocks.md).
//
// Use it when the answer is a set of values the caller will compare or revisit
// (options with prices, a small table, three metrics) instead of a sentence.
// The app decides placement; the envelope rides the reply and is delivered
// automatically, so do not restate the contents in the spoken reply — say what
// the view is for and let the caller look at it.
export default defineTool({
  description:
    "Show the caller a small interactive view (values to compare, options, a " +
    "few metrics) instead of describing them in words. The app draws it " +
    "natively from its own components; you supply data only. Components: " +
    "Text{value}, Metric{label,value}, Card{title,children}, Row{children}, " +
    "Button{label,action}, Divider, Spacer. Props are strings and a node's " +
    "children are ids of other elements. Unknown components are dropped, so a " +
    "wrong component loses that part of the view. Prefer this over a long " +
    "spoken answer, and say only briefly what the view shows.",
  inputSchema: z.object({
    id: z
      .string()
      .min(1)
      .describe("Stable id for this view, so a later render of the same view replaces it (e.g. 'options')."),
    title: z.string().optional().describe("Short title shown above the view."),
    root: z.string().min(1).describe("Id of the element to start from."),
    elements: z
      .record(z.string(), z.unknown())
      .describe(
        "Element id -> {type, props?, children?}. Example: {\"root\":{\"type\":\"Metric\",\"props\":{\"label\":\"per month\",\"value\":\"40\"}}}",
      ),
  }),
  async execute(input, ctx) {
    // The spec shape is the protocol's (`{id, root, elements}`), the same one
    // Rust and the apps parse: nesting matters, the elements are not top-level.
    const spec = { id: input.id, root: input.root, elements: input.elements };
    const body = { title: input.title ?? null, spec };
    emitEnvelope(ctx.session.id, `IDFON-RENDER/1\n${JSON.stringify(body)}`);
    return { rendered: true };
  },
});
