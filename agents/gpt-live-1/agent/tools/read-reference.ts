import { defineTool } from "eve/tools";
import { z } from "zod";
import idfonExtension from "eve-idfon";

// Resolve the part of an artifact that an IDFON-REF/1 envelope points at.
// The ref carries the artifact's blob ticket and its selector; fetch the bytes
// through the idfon bridge and extract the selection so the model reasons
// about the exact thing the user indicated. See docs/idfon-artifacts.md.

const bridgeUrl = () =>
  process.env.EVE_IDFON_BRIDGE_URL || idfonExtension.config?.bridgeUrl || "http://127.0.0.1:18766";
const bridgeSecret = () =>
  process.env.EVE_IDFON_SECRET || idfonExtension.config?.secret || "m2-test-secret";

const MAX_PREVIEW = 4000;

/** RFC 6901 JSON pointer. */
function resolvePointer(root: unknown, pointer: string): unknown {
  if (pointer === "") return root;
  return pointer
    .split("/")
    .slice(1)
    .reduce<unknown>((node, raw) => {
      const token = raw.replace(/~1/g, "/").replace(/~0/g, "~");
      if (Array.isArray(node)) return node[Number(token)];
      if (node && typeof node === "object") return (node as Record<string, unknown>)[token];
      return undefined;
    }, root);
}

export default defineTool({
  description:
    "Read the part of an artifact that a reference points at. Pass the " +
    "blob_ticket and selector from the IDFON-REF/1 (or IDFON-ARTIFACT/1) " +
    "envelope. Returns the selected text, a JSON subtree, or a whole-content " +
    "preview. Call it before answering about a reference.",
  inputSchema: z.object({
    ticket: z.string().min(1).describe("blob_ticket from the envelope"),
    selector: z.record(z.string(), z.unknown()).describe("selector object from the envelope"),
  }),
  async execute({ ticket, selector }) {
    const response = await fetch(`${bridgeUrl()}/blob`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": bridgeSecret(),
      },
      body: JSON.stringify({ ticket }),
    });
    if (!response.ok) throw new Error(`idfon blob fetch returned HTTP ${response.status}`);
    const result = (await response.json()) as { bytes_base64: string };
    const bytes = Buffer.from(result.bytes_base64, "base64");
    const type = String((selector as { type?: unknown }).type ?? "whole");

    switch (type) {
      case "text": {
        const start = Number((selector as { start?: unknown }).start ?? 0);
        const end = Number((selector as { end?: unknown }).end ?? bytes.length);
        return { kind: "text", content: bytes.subarray(start, end).toString("utf8") };
      }
      case "json_pointer": {
        let json: unknown;
        try {
          json = JSON.parse(bytes.toString("utf8"));
        } catch {
          throw new Error("artifact is not JSON");
        }
        const pointer = String((selector as { pointer?: unknown }).pointer ?? "");
        return { kind: "json", content: JSON.stringify(resolvePointer(json, pointer)) };
      }
      case "whole":
        return { kind: "text", content: bytes.toString("utf8").slice(0, MAX_PREVIEW) };
      case "region":
        // The app crops the region and sends it as this turn's attachment, so a
        // vision-capable model can see the exact pixels; the selector carries
        // the coordinates for reference.
        return {
          kind: "region",
          coordinates: selector,
          note:
            "The selected region was cropped and attached to this turn; look at " +
            "that image. If you cannot see images, say the region was selected " +
            "but you need a description of the whole artifact.",
        };
      default:
        return {
          kind: type,
          coordinates: selector,
          note:
            "This selection cannot be resolved yet; the envelope carries the " +
            "coordinates. Say what it covers instead of guessing.",
        };
    }
  },
});
