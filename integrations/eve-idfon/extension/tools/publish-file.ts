import { defineTool } from "eve/tools";
import { z } from "zod";

import extension from "../extension";

// Durable publication (docs/durable-files.md). The bridge forwards the bytes to
// the edge (or the blob store for `durable: false`), so this works from an
// agent that has no daemon socket. The edge owns the policy: user publishes are
// capped at 2 MB and expire after 24 h; `permanent` needs the ops token.

export default defineTool({
  description:
    "Publish a file or text so it outlives the session: a content-addressed URL " +
    "served by the idfon edge and its CDN. User publishes are capped at 2 MB and " +
    "expire after 24 hours; use `permanent` only for service/model files (needs " +
    "the edge operations token). Set `durable: false` for a connected-only " +
    "BlobTicket instead. The local bridge accepts bodies up to 8 MB (base64).",
  inputSchema: z.object({
    path: z.string().optional().describe("Sandbox path of the file to publish"),
    content: z.string().optional().describe("Text content instead of a file"),
    name: z
      .string()
      .optional()
      .describe("Mutable path to also serve it at, e.g. 'reports/q3.html'"),
    durable: z
      .boolean()
      .optional()
      .describe("Pin on the edge (default true); false returns a connected-only BlobTicket"),
    expires_in: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Seconds; user pins default to and are capped at 24 hours"),
    permanent: z
      .boolean()
      .optional()
      .describe("Operational file, never expires (requires the ops token)"),
  }),
  async execute({ path, content, name, durable, expires_in, permanent }, ctx) {
    let bytes: Buffer;
    if (path) {
      const sandbox = await ctx.getSandbox();
      const file = await sandbox.readBinaryFile({ path });
      if (!file || file.length === 0) throw new Error(`file not found at ${path}`);
      bytes = Buffer.from(file);
    } else if (content !== undefined) {
      bytes = Buffer.from(content, "utf8");
    } else {
      throw new Error("publish_file needs path or content");
    }
    if (permanent && !durable) {
      throw new Error("permanent requires a durable publish");
    }
    if (permanent && expires_in !== undefined) {
      throw new Error("permanent and expires_in are exclusive");
    }

    const headers = {
      "content-type": "application/json",
      "x-idfon-channel-secret": extension.config.secret,
    };
    if (durable === false) {
      const response = await fetch(`${extension.config.bridgeUrl}/blob/put`, {
        method: "POST",
        headers,
        body: JSON.stringify({ bytes_base64: bytes.toString("base64") }),
      });
      if (!response.ok) {
        throw new Error(`blob put returned HTTP ${response.status}: ${(await response.text()).trim()}`);
      }
      const blob = (await response.json()) as { ticket: string; size_bytes: number };
      return { ticket: blob.ticket, size_bytes: blob.size_bytes, durable: false };
    }

    const response = await fetch(`${extension.config.bridgeUrl}/files/publish`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        bytes_base64: bytes.toString("base64"),
        name,
        expires_in,
        permanent: permanent ?? false,
      }),
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`publish returned HTTP ${response.status}: ${text.trim()}`);
    }
    return JSON.parse(text) as {
      url: string;
      cdn_url?: string;
      name_url?: string;
      sha256: string;
      size: number;
      existed: boolean;
      expires_at?: number;
    };
  },
});
