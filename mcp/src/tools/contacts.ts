import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";
import { contactShape } from "../schemas";

export function registerContactTools(server: McpServer): void {
  defineTool(server, {
    name: "contact_search",
    description:
      "Search Apple Contacts by name, or by email address when the query contains '@'. Read-only, always. " +
      "Returns id, name, emails, phones, birthday, postal addresses. Use to resolve WHICH person a task/event " +
      "refers to (put their email in the event notes) or to rank known senders in mail triage.",
    input: {
      query: z.string().describe("Name fragment (e.g. 'sarah') or an email address."),
      limit: z.number().int().optional().describe("Max results (default 10)."),
    },
    output: { contacts: z.array(z.object(contactShape)) },
    annotations: { title: "Search contacts", readOnlyHint: true },
    argv: ({ query, limit }) => {
      const args = ["contacts", "search", query];
      if (limit !== undefined) args.push("--limit", String(limit));
      return args;
    },
    wrap: (parsed) => ({ contacts: parsed }),
  });

  defineTool(server, {
    name: "contact_show",
    description: "Show one Apple Contact by identifier (from contact_search). Read-only.",
    input: {
      id: z.string().describe("Contact identifier."),
    },
    output: contactShape,
    annotations: { title: "Show contact", readOnlyHint: true },
    argv: ({ id }) => ["contacts", "show", id],
  });
}
