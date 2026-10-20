import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";
import { gmailHeaderShape, mailHeaderShape } from "../schemas";

export function registerMailTools(server: McpServer): void {
  defineTool(server, {
    name: "mail_draft",
    description:
      "Create a DRAFT in Mail.app — never sends; the human reviews and hits send. Either a new message " +
      "(to + subject) or a reply (reply_to: an RFC Message-ID from a [mail] task's notes, or a numeric id " +
      "from mail_scan; threading preserved, subject defaults to Re: <original>).",
    input: {
      to: z.array(z.string()).optional().describe("Recipient addresses. Required unless reply_to."),
      subject: z.string().optional().describe("Required for new drafts; optional override for replies."),
      body: z.string().describe("Draft body text."),
      reply_to: z.string().optional().describe("Message to reply to (RFC Message-ID or mail_scan numeric id)."),
    },
    // MailDraft.Out (Sources/AppleTasks/Mail.swift)
    output: {
      drafted: z.boolean(),
      mode: z.enum(["new", "reply"]),
      to: z.array(z.string()),
      subject: z.string(),
      inReplyTo: z.string().optional().describe("Reply mode: id of the message being replied to."),
    },
    annotations: { title: "Draft mail", destructiveHint: true },
    timeoutMs: 60_000,
    argv: ({ to, subject, body, reply_to }) => {
      const args = ["mail", "draft", "--body", body];
      for (const addr of to ?? []) args.push("--to", addr);
      if (subject) args.push("--subject", subject);
      if (reply_to) args.push("--reply-to", reply_to);
      return args;
    },
  });

  defineTool(server, {
    name: "mail_scan",
    description:
      "List Mail.app inbox message headers (id, subject, from, received, read) since a timestamp. " +
      "Headers only, newest first; use mail_show for a body. Read-only.",
    input: {
      since: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601 (default: 24h ago)."),
      limit: z.number().int().optional().describe("Max messages (default 50)."),
    },
    output: { messages: z.array(z.object(mailHeaderShape)) },
    annotations: { title: "Scan mail", readOnlyHint: true },
    argv: ({ since, limit }) => {
      const args = ["mail", "scan"];
      if (since) args.push("--since", since);
      if (limit !== undefined) args.push("--limit", String(limit));
      return args;
    },
    wrap: (parsed) => ({ messages: parsed }),
  });

  defineTool(server, {
    name: "mail_show",
    description: "Show one Mail.app inbox message including its plain-text body.",
    input: {
      id: z.string().describe("Message id from mail_scan."),
      max_chars: z.number().int().optional().describe("Truncate the body (default 4000)."),
    },
    output: { ...mailHeaderShape, body: z.string() },
    annotations: { title: "Show mail", readOnlyHint: true },
    argv: ({ id, max_chars }) => {
      const args = ["mail", "show", id];
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
  });

  defineTool(server, {
    name: "gmail_scan",
    description:
      "List Gmail inbox messages newer than the last scan (watermarked capture feed; first call looks back 24h). " +
      "Headers + snippet only, newest first; use gmail_show for a body. Read-only scope — no send path exists. " +
      "Needs a one-time 'apple-tasks gmail login' from a terminal.",
    input: {
      limit: z.number().int().optional().describe("Max messages, newest first (default 50)."),
      query: z.string().optional().describe("Extra Gmail search terms ANDed with the watermark (e.g. 'from:boss@example.com')."),
    },
    output: { messages: z.array(z.object({ ...gmailHeaderShape, snippet: z.string() })) },
    annotations: { title: "Scan Gmail", readOnlyHint: true, openWorldHint: true },
    argv: ({ limit, query }) => {
      const args = ["gmail", "scan"];
      if (limit !== undefined) args.push("--limit", String(limit));
      if (query) args.push("--query", query);
      return args;
    },
    wrap: (parsed) => ({ messages: parsed }),
  });

  defineTool(server, {
    name: "gmail_show",
    description: "Show one Gmail message including its plain-text body. Read-only.",
    input: {
      id: z.string().describe("Message id from gmail_scan."),
      max_chars: z.number().int().optional().describe("Truncate the body (default 4000)."),
    },
    output: { ...gmailHeaderShape, body: z.string() },
    annotations: { title: "Show Gmail", readOnlyHint: true, openWorldHint: true },
    argv: ({ id, max_chars }) => {
      const args = ["gmail", "show", id];
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
  });
}
