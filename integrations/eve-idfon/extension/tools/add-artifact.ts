import { defineTool } from "eve/tools";
import { z } from "zod";
import { randomUUID } from "node:crypto";

import extension from "../extension";
import { emitEnvelope } from "../outbox";

// Publish a durable artifact for the user (docs/idfon-artifacts.md). Bytes go
// through the bridge blob store; the IDFON-ARTIFACT/1 envelope is emitted to the
// outbox and rides the reply, so the model does not echo it. Available to any
// idfon-aware agent, not just voice agents.

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
  const ext = title.toLowerCase().split(".").pop() ?? "";
  return MIME_BY_EXTENSION[ext] ?? "text/plain";
}

export default defineTool({
  description:
    "Publish a result as an artifact the user can open in the chat thread — a report, " +
    "table, JSON, chart, or any file worth viewing in detail. The app shows it " +
    "automatically; do not restate the content in your reply.",
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
    const response = await fetch(`${extension.config.bridgeUrl}/blob/put`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-idfon-channel-secret": extension.config.secret,
      },
      body: JSON.stringify({ bytes_base64: bytes.toString("base64") }),
    });
    if (!response.ok) throw new Error(`idfon blob put returned HTTP ${response.status}`);
    const blob = (await response.json()) as { ticket: string; size_bytes: number };

    const artifactId = randomUUID();
    const artifact = {
      artifact_id: artifactId,
      kind: kind ?? inferKind(resolvedMime),
      mime: resolvedMime,
      title,
      size_bytes: blob.size_bytes,
      blob_ticket: blob.ticket,
      created_at: new Date().toISOString(),
      ...(metadata ? { metadata } : {}),
    };
    emitEnvelope(ctx.session.id, `IDFON-ARTIFACT/1\n${JSON.stringify(artifact)}`);
    return { artifact_id: artifactId, ticket: blob.ticket, size_bytes: blob.size_bytes };
  },
});
