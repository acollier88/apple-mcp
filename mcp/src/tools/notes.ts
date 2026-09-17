import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";

export function registerNotesTools(server: McpServer): void {
  defineTool(server, {
    name: "notes_scan",
    description:
      "List Apple Notes modified since the last scan (watermark auto-advances; first run looks back 24h). " +
      "Returns plain-text bodies. Read-only. Use this to find action items that should become tasks (task_create) " +
      "or events (event_create); put the source note's name in the created item's notes field for provenance.",
    input: {
      folder: z.string().optional().describe("Only scan this Notes folder."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each note body (default 4000)."),
    },
    // NoteOut (Sources/AppleTasks/Notes.swift)
    output: {
      notes: z.array(z.object({
        id: z.string(),
        name: z.string(),
        folder: z.string().optional().describe("Present only when the scan was folder-filtered."),
        body: z.string().describe("Plain text (HTML stripped), truncated to max_chars."),
        created: z.string(),
        modified: z.string(),
      })),
    },
    annotations: { title: "Scan notes", readOnlyHint: true },
    argv: ({ folder, since, max_chars }) => {
      const args = ["notes", "scan"];
      if (folder) args.push("--folder", folder);
      if (since) args.push("--since", since);
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
    wrap: (parsed) => ({ notes: parsed }),
  });

  defineTool(server, {
    name: "note_create",
    description:
      "Create a NEW Apple Note (existing notes are never edited). Body is HTML; the title is " +
      "prepended as an <h1> and becomes the note's name.",
    input: {
      title: z.string().describe("Note title (first line of the note)."),
      body_html: z.string().describe("Note body as HTML."),
      folder: z.string().optional().describe("Notes folder (default: the default folder)."),
    },
    // NotesCreate (Sources/AppleTasks/Digest.swift) prints {id, name} from JXA.
    output: { id: z.string(), name: z.string() },
    annotations: { title: "Create note", destructiveHint: true },
    argv: ({ title, body_html, folder }) => {
      const args = ["notes", "create", "--title", title];
      if (folder) args.push("--folder", folder);
      args.push(body_html);
      return args;
    },
  });
}
