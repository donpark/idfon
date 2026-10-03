import { defineTool } from "eve/tools";
import { z } from "zod";
import { randomUUID } from "node:crypto";
import idfonExtension from "eve-idfon";

// Publish an agent result as a durable artifact the user can open in the chat
// thread. The bytes go through the idfon bridge's blob store; the returned
// IDFON-ARTIFACT/1 envelope rides back in the reply text, and the app renders
// a card and fetches the blob by ticket. See docs/idfon-artifacts.md.

const bridgeUrl = () =>
  process.env.EVE_IDFON_BRIDGE_URL || idfonExtension.config?.bridgeUrl || "http://127.0.0.1:18766";
const bridgeSecret = () =>
  process.env.EVE_IDFON_SECRET || idfonExtension.config?.secret || "m2-test-secret";

const KINDS = ["document", "image", "audio", "video", "data", "html", "live"] as const;
type Kind = (typeof KINDS)[number];

function inferKind(mime: string): Kind {
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  if (mime.includes("html")) return "html";
  if (mime.includes("json") || mime.includes("csv")) return "data";
  return "document";
}

const MIME_BY_EXTENSION: Record<string, string> = {
  md: "text/markdown", txt: "text/plain", json: "application/json",
  csv: "text/csv", html: "text/html", svg: "image/svg+xml",
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp",
  gif: "image/gif", pdf: "application/pdf", wav: "audio/wav",
  mp3: "audio/mpeg", ogg: "audio/ogg", mp4: "video/mp4",
};

function inferMime(title: string): string {
  const extension = title.toLowerCase().split(".").pop() ?? "";
  return MIME_BY_EXTENSION[extension] ?? "text/plain";
}

export default defineTool({
  description:
    "Publish a result as an artifact the user can open in the chat thread — a report, " +
    "table, JSON, chart, or any file the user should be able to view in detail. " +
    "Returns an IDFON-ARTIFACT/1 envelope; include it verbatim in your reply text.",
  inputSchema: z.object({
    title: z.string().min(1).describe("Short filename-like title, e.g. 'q3-summary.md'"),
    content: z.string().optional().describe("Text content of the artifact"),
    path: z.string().optional().describe("Sandbox path of a file to publish instead of content"),
    mime: z.string().optional().describe("Override the inferred MIME type"),
    kind: z.enum(KINDS).optional().describe("Override the inferred artifact kind"),
    metadata: z.record(z.string(), z.unknown()).optional().describe("Renderer hints (schema, dimensions, ...)"),
  }),
  async execute({ title, content, path, mime, kind, metadata }, ctx) {
    let bytes: Buffer;
    if (path) {
      const sandbox = await ctx.getSandbox();
      const file = await sandbox.readBinaryFile({ path });
      if (!file || file.length === 0) throw new Error(`artifact file not found at ${path}`);
      bytes = Buffer.from(file);
    } else if (content !== undefined) {
      bytes = Buffer.from(content, "utf8");
    } else {
      throw new Error("add_artifact needs content or path");
    }

    const resolvedMime = mime ?? inferMime(title);
    const resolvedKind = kind ?? inferKind(resolvedMime);

    const response = await fetch(`${bridgeUrl()}/blob/put`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": bridgeSecret(),
      },
      body: JSON.stringify({ bytes_base64: bytes.toString("base64") }),
    });
    if (!response.ok) throw new Error(`idfon blob put returned HTTP ${response.status}`);
    const blob = (await response.json()) as { ticket: string; size_bytes: number };

    const artifactId = randomUUID();
    const artifact = {
      artifact_id: artifactId,
      kind: resolvedKind,
      mime: resolvedMime,
      title,
      size_bytes: blob.size_bytes,
      blob_ticket: blob.ticket,
      created_at: new Date().toISOString(),
      ...(metadata ? { metadata } : {}),
    };

    return {
      artifact_id: artifactId,
      ticket: blob.ticket,
      size_bytes: blob.size_bytes,
      envelope: `IDFON-ARTIFACT/1\n${JSON.stringify(artifact)}`,
    };
  },
});
