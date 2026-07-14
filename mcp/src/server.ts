import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";

const execFileAsync = promisify(execFile);

const BIN =
  process.env.APPLE_TASKS_BIN ??
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.build/release/apple-tasks");

async function cli(args: string[], timeoutMs = 30_000): Promise<string> {
  try {
    const { stdout } = await execFileAsync(BIN, args, {
      timeout: timeoutMs,
      env: { ...process.env, APPLE_TASKS_CALLER: "mcp" },
    });
    return stdout.trim();
  } catch (err: any) {
    const detail = err.stderr?.trim() || err.message;
    throw new Error(detail);
  }
}

function ok(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

/**
 * ok() plus structuredContent parsed from the CLI's JSON stdout. The MCP spec
 * requires structuredContent to be an object, so tools whose CLI output is a
 * top-level JSON array pass `wrap` to fold it into a single named key;
 * content[0].text always carries the raw CLI JSON unchanged.
 */
function okJson(text: string, wrap?: string) {
  const parsed = JSON.parse(text) as Record<string, unknown> | unknown[];
  return {
    content: [{ type: "text" as const, text }],
    structuredContent: (wrap ? { [wrap]: parsed } : parsed) as Record<string, unknown>,
  };
}

function fail(err: unknown) {
  return {
    content: [{ type: "text" as const, text: String(err instanceof Error ? err.message : err) }],
    isError: true,
  };
}

const tagsField = z
  .array(z.string())
  .optional()
  .describe("Tags (no spaces/brackets, e.g. 'claude', 'repo2'). Stored as [tag] prefixes on the reminder title.");

// ---- Output shapes. These mirror the JSON the Swift CLI emits (see the
// output structs in Sources/AppleTasks/*.swift); the MCP server adds no
// fields of its own. Swift's encodeIfPresent omits nil keys, hence .optional().

// TaskOut (Sources/AppleTasks/Support.swift)
const taskShape = {
  id: z.string(),
  externalId: z.string().optional().describe("Sync-stable identifier; also accepted wherever a task id is."),
  title: z.string().describe("Title with [tag] prefixes stripped."),
  rawTitle: z.string(),
  tags: z.array(z.string()),
  list: z.string(),
  notes: z.string().optional(),
  due: z.string().optional(),
  priority: z.enum(["none", "low", "medium", "high"]),
  completed: z.boolean(),
  completedAt: z.string().optional(),
  createdAt: z.string().optional(),
  url: z.string().optional(),
  nativeTags: z.boolean().optional().describe("add/update only: whether tags were mirrored to native Reminders tags."),
  subtask: z.boolean().optional().describe("update only: whether a --parent subtask change was applied."),
  recurrence: z.string().optional().describe("RRULE subset (e.g. 'FREQ=WEEKLY;BYDAY=MO'); absent = one-shot."),
  recurred: z
    .boolean()
    .optional()
    .describe("complete only: completing this recurring task rolled it to the next occurrence (shown still open)."),
};
const taskSchema = z.object(taskShape);

// EventOut (Sources/AppleTasks/Support.swift)
const eventShape = {
  id: z.string(),
  title: z.string().describe("Title with [tag] prefixes stripped."),
  rawTitle: z.string(),
  tags: z.array(z.string()),
  calendar: z.string(),
  start: z.string().optional().describe("yyyy-MM-dd for all-day events, ISO8601 otherwise."),
  end: z.string().optional(),
  allDay: z.boolean(),
  location: z.string().optional(),
  notes: z.string().optional(),
  url: z.string().optional(),
  recurrence: z.string().optional().describe("RRULE subset (e.g. 'FREQ=WEEKLY;BYDAY=MO'); absent = one-shot."),
};
const eventSchema = z.object(eventShape);

// ListOut / CalendarOut (Sources/AppleTasks/Support.swift)
const listShape = { id: z.string(), name: z.string() };
const calendarShape = { id: z.string(), name: z.string(), writable: z.boolean() };

// `delete` / `events delete` emit {"deleted": <id>}.
const deletedShape = { deleted: z.string().describe("Id of the deleted item.") };

const server = new McpServer({ name: "apple-tasks", version: "0.1.0" });

server.registerTool(
  "task_list",
  {
    description:
      "List tasks from Apple Reminders. Filter by list (plan), tags (AND), and status. Returns JSON tasks with parsed tags.",
    inputSchema: {
      list: z.string().optional().describe("Reminders list name (a plan). Omit for all lists."),
      tags: tagsField,
      status: z.enum(["open", "completed", "all"]).optional().describe("Default: open."),
      due_before: z
        .string()
        .optional()
        .describe("Only tasks due before this date (yyyy-MM-dd inclusive of that day, 'yyyy-MM-dd HH:mm', or ISO8601). Undated tasks are excluded."),
      overdue: z.boolean().optional().describe("Only tasks whose due date has passed (excludes undated tasks)."),
    },
    outputSchema: { tasks: z.array(taskSchema) },
  },
  async ({ list, tags, status, due_before, overdue }) => {
    const args = ["list"];
    if (list) args.push("--list", list);
    for (const t of tags ?? []) args.push("--tag", t);
    if (status) args.push("--status", status);
    if (due_before) args.push("--due-before", due_before);
    if (overdue) args.push("--overdue");
    try {
      return okJson(await cli(args), "tasks");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_create",
  {
    description:
      "Create a task in a Reminders list. Tags become a [tag] prefix on the title (e.g. '[claude][repo2] Add MFA').",
    inputSchema: {
      list: z.string().describe("Reminders list name to create the task in (required)."),
      title: z.string().describe("Task title, without tag prefix."),
      tags: tagsField,
      notes: z.string().optional(),
      due: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601."),
      priority: z.enum(["none", "low", "medium", "high"]).optional(),
      url: z.string().optional().describe("URL to attach (PR/artifact links)."),
      recurrence: z
        .string()
        .optional()
        .describe(
          "Repeat rule, requires due. RRULE subset: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY;INTERVAL=n;BYDAY=MO,WE;BYMONTHDAY=1,15;UNTIL=yyyy-MM-dd|COUNT=n. Completing an occurrence rolls the task to the next one."),
    },
    outputSchema: taskShape,
  },
  async ({ list, title, tags, notes, due, priority, url, recurrence }) => {
    const args = ["add", "--list", list];
    for (const t of tags ?? []) args.push("--tag", t);
    if (notes) args.push("--notes", notes);
    if (due) args.push("--due", due);
    if (priority) args.push("--priority", priority);
    if (url) args.push("--url", url);
    if (recurrence) args.push("--recurrence", recurrence);
    args.push(title);
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_update",
  {
    description: "Update a task: retitle, add/remove tags, notes, due date, priority, or move to another list.",
    inputSchema: {
      id: z.string().describe("Task id from task_list/task_create."),
      title: z.string().optional().describe("New title (tags are preserved)."),
      add_tags: z.array(z.string()).optional(),
      remove_tags: z.array(z.string()).optional(),
      notes: z.string().optional().describe("Replace the notes body."),
      append_notes: z.string().optional().describe(
        "Append a paragraph to the notes, keeping the existing body (use for outcome summaries)."),
      due: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601."),
      clear_due: z.boolean().optional(),
      priority: z.enum(["none", "low", "medium", "high"]).optional(),
      list: z.string().optional().describe("Move the task to this list."),
      url: z.string().optional().describe("Set the task URL (PR/artifact links)."),
      clear_url: z.boolean().optional(),
      parent: z
        .string()
        .optional()
        .describe("Make this task a subtask of the given task id (native Reminders subtask, via the private helper)."),
      recurrence: z
        .string()
        .optional()
        .describe("Set/replace the repeat rule (task must have a due date). Same RRULE subset as task_create."),
      clear_recurrence: z.boolean().optional().describe("Remove the repeat rule (series stops recurring)."),
    },
    outputSchema: taskShape,
  },
  async ({ id, title, add_tags, remove_tags, notes, append_notes, due, clear_due, priority, list, url, clear_url, parent, recurrence, clear_recurrence }) => {
    const args = ["update", id];
    if (title) args.push("--title", title);
    for (const t of add_tags ?? []) args.push("--add-tag", t);
    for (const t of remove_tags ?? []) args.push("--remove-tag", t);
    if (notes !== undefined) args.push("--notes", notes);
    if (append_notes !== undefined) args.push("--append-notes", append_notes);
    if (url) args.push("--url", url);
    if (clear_url) args.push("--clear-url");
    if (clear_due) args.push("--clear-due");
    if (due) args.push("--due", due);
    if (priority) args.push("--priority", priority);
    if (list) args.push("--list", list);
    if (parent) args.push("--parent", parent);
    if (recurrence) args.push("--recurrence", recurrence);
    if (clear_recurrence) args.push("--clear-recurrence");
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_complete",
  {
    description:
      "Mark a task completed. Recurring tasks roll to their next occurrence instead (response has recurred=true, completed=false, and the next due date).",
    inputSchema: { id: z.string() },
    outputSchema: taskShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["complete", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_delete",
  {
    description: "Delete a task permanently.",
    inputSchema: { id: z.string() },
    outputSchema: deletedShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["delete", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "plan_list",
  {
    description: "List Reminders lists. Each list is a plan; its reminders are the plan's tasks.",
    inputSchema: {},
    outputSchema: { plans: z.array(z.object(listShape)) },
  },
  async () => {
    try {
      return okJson(await cli(["lists"]), "plans");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "plan_create",
  {
    description: "Create a new Reminders list to serve as a plan.",
    inputSchema: { name: z.string().describe("Name for the new list/plan.") },
    outputSchema: listShape,
  },
  async ({ name }) => {
    try {
      return okJson(await cli(["lists", "add", name]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "event_list",
  {
    description:
      "List Calendar events in a date range (default: today through +7 days). Filter by calendar and tags (AND). Same [tag] title convention as tasks.",
    inputSchema: {
      calendar: z.string().optional().describe("Calendar name. Omit for all calendars."),
      tags: tagsField,
      from: z.string().optional().describe("Range start: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Default: start of today."),
      to: z.string().optional().describe("Range end, same formats. Default: from + 7 days."),
    },
    outputSchema: { events: z.array(eventSchema) },
  },
  async ({ calendar, tags, from, to }) => {
    const args = ["events", "list"];
    if (calendar) args.push("--calendar", calendar);
    for (const t of tags ?? []) args.push("--tag", t);
    if (from) args.push("--from", from);
    if (to) args.push("--to", to);
    try {
      return okJson(await cli(args), "events");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "event_create",
  {
    description:
      "Create a Calendar event. A date-only start (yyyy-MM-dd) makes an all-day event. Tags become a [tag] title prefix.",
    inputSchema: {
      calendar: z.string().optional().describe("Calendar name. Omit for the system default calendar."),
      title: z.string().describe("Event title, without tag prefix."),
      tags: tagsField,
      start: z.string().describe("yyyy-MM-dd (all-day), 'yyyy-MM-dd HH:mm', or ISO8601."),
      end: z.string().optional().describe("Same formats. Mutually exclusive with duration."),
      duration: z.number().int().optional().describe("Duration in minutes (default 60 when end omitted)."),
      location: z.string().optional(),
      notes: z.string().optional(),
      url: z.string().optional().describe("URL to attach (PR/artifact links)."),
      recurrence: z
        .string()
        .optional()
        .describe(
          "Repeat rule. RRULE subset: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY;INTERVAL=n;BYDAY=MO,WE;BYMONTHDAY=1,15;UNTIL=yyyy-MM-dd|COUNT=n."),
    },
    outputSchema: eventShape,
  },
  async ({ calendar, title, tags, start, end, duration, location, notes, url, recurrence }) => {
    const args = ["events", "add", "--start", start];
    if (calendar) args.push("--calendar", calendar);
    for (const t of tags ?? []) args.push("--tag", t);
    if (end) args.push("--end", end);
    if (duration !== undefined) args.push("--duration", String(duration));
    if (location) args.push("--location", location);
    if (notes) args.push("--notes", notes);
    if (url) args.push("--url", url);
    if (recurrence) args.push("--recurrence", recurrence);
    args.push(title);
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "event_update",
  {
    description: "Update a Calendar event: retitle, add/remove tags, retime, location, notes, or move calendars.",
    inputSchema: {
      id: z.string().describe("Event id from event_list/event_create."),
      title: z.string().optional().describe("New title (tags are preserved)."),
      add_tags: z.array(z.string()).optional(),
      remove_tags: z.array(z.string()).optional(),
      start: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601."),
      end: z.string().optional(),
      location: z.string().optional(),
      notes: z.string().optional(),
      calendar: z.string().optional().describe("Move the event to this calendar."),
      url: z.string().optional().describe("Set the event URL (PR/artifact links)."),
      clear_url: z.boolean().optional(),
    },
    outputSchema: eventShape,
  },
  async ({ id, title, add_tags, remove_tags, start, end, location, notes, calendar, url, clear_url }) => {
    const args = ["events", "update", id];
    if (url) args.push("--url", url);
    if (clear_url) args.push("--clear-url");
    if (title) args.push("--title", title);
    for (const t of add_tags ?? []) args.push("--add-tag", t);
    for (const t of remove_tags ?? []) args.push("--remove-tag", t);
    if (start) args.push("--start", start);
    if (end) args.push("--end", end);
    if (location !== undefined) args.push("--location", location);
    if (notes !== undefined) args.push("--notes", notes);
    if (calendar) args.push("--calendar", calendar);
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "event_delete",
  {
    description: "Delete a Calendar event permanently.",
    inputSchema: { id: z.string() },
    outputSchema: deletedShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["events", "delete", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "calendar_list",
  {
    description: "List Calendar calendars with writability.",
    inputSchema: {},
    outputSchema: { calendars: z.array(z.object(calendarShape)) },
  },
  async () => {
    try {
      return okJson(await cli(["calendars"]), "calendars");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "notes_scan",
  {
    description:
      "List Apple Notes modified since the last scan (watermark auto-advances; first run looks back 24h). " +
      "Returns plain-text bodies. Read-only. Use this to find action items that should become tasks (task_create) " +
      "or events (event_create); put the source note's name in the created item's notes field for provenance.",
    inputSchema: {
      folder: z.string().optional().describe("Only scan this Notes folder."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each note body (default 4000)."),
    },
    // NoteOut (Sources/AppleTasks/Notes.swift)
    outputSchema: {
      notes: z.array(z.object({
        id: z.string(),
        name: z.string(),
        folder: z.string().optional().describe("Present only when the scan was folder-filtered."),
        body: z.string().describe("Plain text (HTML stripped), truncated to max_chars."),
        created: z.string(),
        modified: z.string(),
      })),
    },
  },
  async ({ folder, since, max_chars }) => {
    const args = ["notes", "scan"];
    if (folder) args.push("--folder", folder);
    if (since) args.push("--since", since);
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    try {
      return okJson(await cli(args), "notes");
    } catch (err) {
      return fail(err);
    }
  }
);

// ContactOut (Sources/AppleTasks/Contacts.swift)
const contactShape = {
  id: z.string(),
  name: z.string(),
  nickname: z.string().optional(),
  organization: z.string().optional(),
  emails: z.array(z.string()),
  phones: z.array(z.string()),
  birthday: z.string().optional().describe("yyyy-MM-dd, or MM-dd when the year is unknown."),
  postalAddresses: z.array(z.string()),
};

server.registerTool(
  "contact_search",
  {
    description:
      "Search Apple Contacts by name, or by email address when the query contains '@'. Read-only, always. " +
      "Returns id, name, emails, phones, birthday, postal addresses. Use to resolve WHICH person a task/event " +
      "refers to (put their email in the event notes) or to rank known senders in mail triage.",
    inputSchema: {
      query: z.string().describe("Name fragment (e.g. 'sarah') or an email address."),
      limit: z.number().int().optional().describe("Max results (default 10)."),
    },
    outputSchema: { contacts: z.array(z.object(contactShape)) },
  },
  async ({ query, limit }) => {
    const args = ["contacts", "search", query];
    if (limit !== undefined) args.push("--limit", String(limit));
    try {
      return okJson(await cli(args), "contacts");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "contact_show",
  {
    description: "Show one Apple Contact by identifier (from contact_search). Read-only.",
    inputSchema: {
      id: z.string().describe("Contact identifier."),
    },
    outputSchema: contactShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["contacts", "show", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "note_create",
  {
    description:
      "Create a NEW Apple Note (existing notes are never edited). Body is HTML; the title is " +
      "prepended as an <h1> and becomes the note's name.",
    inputSchema: {
      title: z.string().describe("Note title (first line of the note)."),
      body_html: z.string().describe("Note body as HTML."),
      folder: z.string().optional().describe("Notes folder (default: the default folder)."),
    },
    // NotesCreate (Sources/AppleTasks/Digest.swift) prints {id, name} from JXA.
    outputSchema: { id: z.string(), name: z.string() },
  },
  async ({ title, body_html, folder }) => {
    const args = ["notes", "create", "--title", title];
    if (folder) args.push("--folder", folder);
    args.push(body_html);
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "digest",
  {
    description:
      "Morning digest: agent activity since yesterday (audit log), dispatch outcomes, tasks due today, " +
      "and today's calendar, as one JSON blob. Optionally writes it as a new Apple Note (note: true) " +
      "and/or pushes a one-line summary to the configured ntfy topic (push: true).",
    inputSchema: {
      since: z.string().optional().describe("Look-back start (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601; default 24h ago)."),
      note: z.boolean().optional().describe("Write the digest as a new Apple Note."),
      note_folder: z.string().optional().describe("Notes folder for the digest note."),
      push: z.boolean().optional().describe("Send a short summary to the configured ntfy topic."),
    },
    // DigestOut (Sources/AppleTasks/Digest.swift)
    outputSchema: {
      since: z.string(),
      generatedAt: z.string(),
      dispatches: z.array(z.object({
        id: z.number().int(),
        agent: z.string(),
        status: z.string(),
        summary: z.string().optional(),
        taskId: z.string(),
      })),
      auditActions: z.number().int(),
      auditByCommand: z.record(z.number().int()),
      dueToday: z.array(taskSchema),
      events: z.array(eventSchema),
      noteCreated: z.string().optional().describe("Created note id when note: true."),
      pushed: z.boolean().optional().describe("Whether the ntfy push succeeded when push: true."),
    },
  },
  async ({ since, note, note_folder, push }) => {
    const args = ["digest"];
    if (since) args.push("--since", since);
    if (note) args.push("--note");
    if (note_folder) args.push("--note-folder", note_folder);
    if (push) args.push("--push");
    try {
      return okJson(await cli(args, 60_000));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "screenshots_scan",
  {
    description:
      "OCR screenshots/images modified since the last scan (watermark auto-advances; first run looks back 24h). " +
      "On-device Vision, read-only. Returns {file, modified, text} per image. Use to turn 'screenshot it to deal " +
      "with later' captures into tasks/events (task_create/event_create); keep the file path as provenance.",
    inputSchema: {
      dir: z.string().optional().describe("Folder to scan (default: ~/Desktop)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each image's text (default 4000)."),
    },
    // ScreenshotOut (Sources/AppleTasks/Screenshots.swift)
    outputSchema: {
      screenshots: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        text: z.string().describe("Recognized text; empty when the image has none."),
      })),
    },
  },
  async ({ dir, since, max_chars }) => {
    const args = ["screenshots", "scan"];
    if (dir) args.push("--dir", dir);
    if (since) args.push("--since", since);
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    try {
      return okJson(await cli(args, 120_000), "screenshots"); // OCR of many images can be slow
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "files_scan",
  {
    description:
      "Read .txt/.md files dropped in the iCloud inbox folder since the last scan (watermark auto-advances; " +
      "first run looks back 24h). The universal capture escape hatch — any device drops a file, this emits " +
      "{file, modified, content}. Set archive:true to move processed files into a done/ subfolder.",
    inputSchema: {
      dir: z.string().optional().describe("Folder to scan (default: iCloud Drive/AgentInbox)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each file's content (default 8000)."),
      archive: z.boolean().optional().describe("Move processed files into a done/ subfolder."),
    },
    // FileDropOut (Sources/AppleTasks/Files.swift)
    outputSchema: {
      files: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        content: z.string(),
        archivedTo: z.string().optional().describe("Destination path when archive: true."),
      })),
    },
  },
  async ({ dir, since, max_chars, archive }) => {
    const args = ["files", "scan"];
    if (dir) args.push("--dir", dir);
    if (since) args.push("--since", since);
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    if (archive) args.push("--archive");
    try {
      return okJson(await cli(args), "files");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "audio_scan",
  {
    description:
      "Transcribe audio notes dropped in the iCloud inbox folder since the last scan (watermark " +
      "auto-advances; first run looks back 24h). On-device Speech recognition; emits {file, modified, " +
      "transcript, error?}. Failed files are retried next scan. Set archive:true to move transcribed " +
      "files into a done/ subfolder.",
    inputSchema: {
      dir: z.string().optional().describe("Folder to scan (default: iCloud Drive/AgentInbox)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each transcript (default 4000)."),
      archive: z.boolean().optional().describe("Move transcribed files into a done/ subfolder."),
    },
    // AudioOut (Sources/AppleTasks/Audio.swift)
    outputSchema: {
      recordings: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        transcript: z.string().optional().describe("Absent when transcription failed (see error)."),
        archivedTo: z.string().optional().describe("Destination path when archive: true."),
        error: z.string().optional(),
      })),
    },
  },
  async ({ dir, since, max_chars, archive }) => {
    const args = ["audio", "scan"];
    if (dir) args.push("--dir", dir);
    if (since) args.push("--since", since);
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    if (archive) args.push("--archive");
    try {
      return okJson(await cli(args, 300_000), "recordings"); // transcription of many memos can be slow
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "readinglist_scan",
  {
    description:
      "Read Safari Reading List items added since the last scan (watermark auto-advances; first run looks " +
      "back 24h). Emits {title, url, dateAdded, previewText}, oldest first. Requires Full Disk Access for " +
      "the host process; the doctor command reports FDA status. Read-only.",
    inputSchema: {
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_items: z.number().int().optional().describe("Limit output to this many items (default 50)."),
    },
    // ReadingListItemOut (Sources/AppleTasks/ReadingList.swift)
    outputSchema: {
      items: z.array(z.object({
        title: z.string(),
        url: z.string(),
        dateAdded: z.string(),
        previewText: z.string().optional(),
      })),
    },
  },
  async ({ since, max_items }) => {
    const args = ["reading-list", "scan"];
    if (since) args.push("--since", since);
    if (max_items !== undefined) args.push("--max-items", String(max_items));
    try {
      return okJson(await cli(args), "items");
    } catch (err) {
      return fail(err);
    }
  }
);

// WatchItemOut / WatchScan.Out (Sources/AppleTasks/Watches.swift)
const watchItemShape = {
  watch: z.string().describe("Name of the watch that produced this item."),
  kind: z.enum(["rss", "url"]),
  ts: z.string().describe("Item timestamp (feed pubDate when parseable, else scan time), ISO8601."),
  title: z.string().optional(),
  url: z.string(),
  note: z.string().optional().describe("'content changed' for url watches; feed summary for rss."),
};

server.registerTool(
  "watch_scan",
  {
    description:
      "Fetch each due topic watch (RSS feeds / web pages from ~/.config/apple-tasks/watches.json) and emit " +
      "items new since the last scan. Per-watch cadence and seen-state; first run records a baseline. " +
      "Failed watches are reported per-watch, never fatal.",
    inputSchema: {
      watch: z.string().optional().describe("Only scan this watch (by name)."),
      force: z.boolean().optional().describe("Fetch every watch now, ignoring cadence."),
      max_items: z.number().int().optional().describe("Per-watch cap on emitted items (default 20)."),
    },
    outputSchema: {
      scannedAt: z.string(),
      items: z.array(z.object(watchItemShape)),
      watches: z.array(z.object({
        name: z.string(),
        status: z.string().describe("'ok', 'skipped: not due', 'baseline recorded', or 'error: ...'."),
        newItems: z.number().int(),
      })),
    },
  },
  async ({ watch, force, max_items }) => {
    const args = ["watch", "scan"];
    if (watch) args.push("--watch", watch);
    if (force) args.push("--force");
    if (max_items !== undefined) args.push("--max-items", String(max_items));
    try {
      return okJson(await cli(args, 120_000)); // N sequential fetches
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "watch_list",
  {
    description: "Show configured topic watches and their scan state (last fetch, due now?).",
    inputSchema: {},
    outputSchema: {
      watches: z.array(z.object({
        name: z.string(),
        kind: z.enum(["rss", "url"]),
        url: z.string(),
        cadenceMinutes: z.number().int(),
        lastFetch: z.string().optional(),
        due: z.boolean(),
      })),
    },
  },
  async () => {
    try {
      return okJson(await cli(["watch", "list"]), "watches");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "web_fetch",
  {
    description:
      "Fetch a URL and return {url, status, title, text} with HTML reduced to readable text. Minimal web " +
      "primitive for agents without their own web access; prefer your native web tools if you have them.",
    inputSchema: {
      url: z.string().describe("http(s) URL to fetch."),
      max_chars: z.number().int().optional().describe("Truncate extracted text (default 4000)."),
    },
    outputSchema: {
      url: z.string(),
      status: z.number().int(),
      contentType: z.string().optional(),
      title: z.string().optional(),
      text: z.string(),
      truncated: z.boolean(),
    },
  },
  async ({ url, max_chars }) => {
    const args = ["web", "fetch", url];
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    try {
      return okJson(await cli(args, 60_000));
    } catch (err) {
      return fail(err);
    }
  }
);

// MailHeaderOut / MailMessageOut (Sources/AppleTasks/Mail.swift)
const mailHeaderShape = {
  id: z.string(),
  subject: z.string(),
  from: z.string(),
  received: z.string(),
  read: z.boolean(),
};

server.registerTool(
  "mail_scan",
  {
    description:
      "List Mail.app inbox message headers (id, subject, from, received, read) since a timestamp. " +
      "Headers only, newest first; use mail_show for a body. Read-only.",
    inputSchema: {
      since: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601 (default: 24h ago)."),
      limit: z.number().int().optional().describe("Max messages (default 50)."),
    },
    outputSchema: { messages: z.array(z.object(mailHeaderShape)) },
  },
  async ({ since, limit }) => {
    const args = ["mail", "scan"];
    if (since) args.push("--since", since);
    if (limit !== undefined) args.push("--limit", String(limit));
    try {
      return okJson(await cli(args), "messages");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "mail_show",
  {
    description: "Show one Mail.app inbox message including its plain-text body.",
    inputSchema: {
      id: z.string().describe("Message id from mail_scan."),
      max_chars: z.number().int().optional().describe("Truncate the body (default 4000)."),
    },
    outputSchema: { ...mailHeaderShape, body: z.string() },
  },
  async ({ id, max_chars }) => {
    const args = ["mail", "show", id];
    if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "shortcut_list",
  {
    // Plain text from the macOS 'shortcuts' CLI (one name per line) — no
    // structured output to declare.
    description: "List the names of all Shortcuts available on this Mac (via the macOS 'shortcuts' CLI).",
    inputSchema: {},
  },
  async () => {
    try {
      const { stdout } = await execFileAsync("shortcuts", ["list"], { timeout: 30_000 });
      return ok(stdout.trim() || "(no shortcuts)");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "shortcut_run",
  {
    // Output is whatever the shortcut prints — genuinely free-form text, so
    // no outputSchema.
    description:
      "Run a macOS Shortcut by name, optionally passing text input, and return its text output. " +
      "Escape hatch to anything Shortcuts can do: HomeKit, Focus modes, notifications, etc.",
    inputSchema: {
      name: z.string().describe("Exact shortcut name (see shortcut_list)."),
      input: z.string().optional().describe("Text passed to the shortcut as input."),
    },
  },
  async ({ name, input }) => {
    const { mkdtemp, writeFile, readFile, rm } = await import("node:fs/promises");
    const os = await import("node:os");
    const dir = await mkdtemp(path.join(os.tmpdir(), "apple-tasks-"));
    const outPath = path.join(dir, "out.txt");
    try {
      const args = ["run", name, "--output-path", outPath];
      if (input !== undefined) {
        const inPath = path.join(dir, "in.txt");
        await writeFile(inPath, input, "utf8");
        args.push("--input-path", inPath);
      }
      await execFileAsync("shortcuts", args, { timeout: 120_000 });
      const output = await readFile(outPath, "utf8").catch(() => "");
      return ok(output.trim() || "(shortcut ran; no output)");
    } catch (err) {
      return fail(err);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
);

server.registerTool(
  "notify",
  {
    // No outputSchema: the local-banner path returns a plain-text ack (it
    // never touches the CLI), so the output isn't uniformly structured.
    description:
      "Show a local macOS notification banner (e.g. to report a finished task). " +
      "push: true also sends it via ntfy so it reaches the user's phone off-Mac " +
      "(requires ~/.config/apple-tasks/notify.json).",
    inputSchema: {
      title: z.string(),
      message: z.string(),
      sound: z.boolean().optional().describe("Play the default notification sound."),
      push: z.boolean().optional().describe("Also push via ntfy."),
    },
  },
  async ({ title, message, sound, push }) => {
    if (push) {
      try {
        return ok(await cli(["notify", title, message, "--push"]));
      } catch (err) {
        return fail(err);
      }
    }
    const body = sound
      ? "display notification (item 2 of argv) with title (item 1 of argv) sound name \"default\""
      : "display notification (item 2 of argv) with title (item 1 of argv)";
    const script = `on run argv\n${body}\nend run`;
    try {
      await execFileAsync("osascript", ["-e", script, title, message], { timeout: 15_000 });
      return ok("notification shown");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "audit_log",
  {
    description:
      "Read the apple-tasks audit log: every mutation (task/event create/update/complete/delete, dispatches) " +
      "with timestamp and caller (mcp/app/dispatcher/terminal). Use to check 'did I already do this?' before acting.",
    inputSchema: {
      since: z.string().optional().describe("ISO8601 or yyyy-MM-dd lower bound."),
      task: z.string().optional().describe("Only entries for this task id."),
      caller: z.string().optional().describe("Caller substring filter (mcp, agent:claude, ...)."),
      limit: z.number().int().optional().describe("Max rows, newest first (default 50)."),
    },
    // AuditDB.AuditRow (Sources/AppleTasks/Audit.swift)
    outputSchema: {
      entries: z.array(z.object({
        ts: z.string(),
        caller: z.string(),
        command: z.string(),
        taskId: z.string().optional(),
        list: z.string().optional(),
        detail: z.string().optional(),
        result: z.string(),
        error: z.string().optional(),
      })),
    },
  },
  async ({ since, task, caller, limit }) => {
    const args = ["log"];
    if (since) args.push("--since", since);
    if (task) args.push("--task", task);
    if (caller) args.push("--caller", caller);
    if (limit !== undefined) args.push("--limit", String(limit));
    try {
      return okJson(await cli(args), "entries");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_show",
  {
    description: "Show a single task by id: full JSON including notes (with dispatch trailers) and tags.",
    inputSchema: { id: z.string().describe("Task id from task_list/dispatch_list.") },
    outputSchema: taskShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["show", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "task_uncomplete",
  {
    description: "Mark a completed task open again.",
    inputSchema: { id: z.string().describe("Task id.") },
    outputSchema: taskShape,
  },
  async ({ id }) => {
    try {
      return okJson(await cli(["uncomplete", id]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "dispatch_run",
  {
    description:
      "Run the agent dispatcher: scan open agent-tagged [auto] tasks, launch configured agents, reap stale " +
      "runs, GC worktrees. dry_run defaults to TRUE (reports what would run, launches nothing); a real run " +
      "(dry_run: false) spawns agent processes, waits for them, and consumes their session budgets. " +
      "reap_only reaps + GCs without dispatching.",
    inputSchema: {
      dry_run: z.boolean().optional().describe("Default true. Set false to actually launch agents."),
      agent: z.string().optional().describe("Only dispatch tasks for this agent tag."),
      list: z.string().optional().describe("Only scan this Reminders list."),
      reap_only: z.boolean().optional().describe("Only reap stale ledger rows and GC worktrees."),
    },
    // Dispatch.DispatchReport (Sources/AppleTasks/Dispatch.swift)
    outputSchema: {
      reports: z.array(z.object({
        taskId: z.string(),
        title: z.string(),
        agent: z.string(),
        cwd: z.string().optional(),
        action: z.string().describe("What happened (dispatched/would dispatch/reaped/gc/skipped...)."),
        exitCode: z.number().int().optional(),
        runLog: z.string().optional(),
        worktree: z.string().optional(),
      })),
    },
  },
  async ({ dry_run, agent, list, reap_only }) => {
    // Dispatched agents may not re-dispatch: an agent whose MCP session was
    // spawned by the dispatcher inherits APPLE_TASKS_CALLER=agent:<tag>.
    if ((process.env.APPLE_TASKS_CALLER ?? "").startsWith("agent:")) {
      return fail("dispatch_run is not available to dispatched agents (no recursive dispatch)");
    }
    const args = ["dispatch"];
    if (dry_run !== false) args.push("--dry-run");
    if (agent) args.push("--agent", agent);
    if (list) args.push("--list", list);
    if (reap_only) args.push("--reap-only");
    try {
      // Real runs execute agents inline; give them 2h, not the 30s default.
      return okJson(await cli(args, dry_run !== false && !reap_only ? 30_000 : 7_200_000), "reports");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "dispatch_list",
  {
    description:
      "Show the dispatch ledger: agent runs with status, exit code, outcome summary, run log path, worktree.",
    inputSchema: {
      status: z.enum(["running", "succeeded", "failed", "timeout", "aborted"]).optional(),
      limit: z.number().int().optional().describe("Max rows (default 50, newest first)."),
    },
    // AuditDB.DispatchRow (Sources/AppleTasks/Audit.swift)
    outputSchema: {
      dispatches: z.array(z.object({
        id: z.number().int(),
        taskId: z.string(),
        agent: z.string(),
        command: z.string(),
        cwd: z.string().optional(),
        startedAt: z.string(),
        finishedAt: z.string().optional(),
        status: z.string(),
        exitCode: z.number().int().optional(),
        runLogPath: z.string().optional(),
        worktree: z.string().optional(),
        summary: z.string().optional(),
      })),
    },
  },
  async ({ status, limit }) => {
    const args = ["dispatches"];
    if (status) args.push("--status", status);
    if (limit) args.push("--limit", String(limit));
    try {
      return okJson(await cli(args), "dispatches");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "run_log",
  {
    // Raw agent output (arbitrary text lines) — no outputSchema.
    description:
      "Read a dispatch run's captured agent output (~/.config/apple-tasks/runs/<ledger_id>.log). " +
      "Returns the last `tail` lines (reads at most the final 256 KB).",
    inputSchema: {
      ledger_id: z.number().int().describe("Ledger row id from dispatch_list."),
      tail: z.number().int().optional().describe("Lines from the end (default 100)."),
    },
  },
  async ({ ledger_id, tail }) => {
    try {
      const fs = await import("node:fs/promises");
      const os = await import("node:os");
      const logPath = path.join(os.homedir(), ".config/apple-tasks/runs", `${ledger_id}.log`);
      const stat = await fs.stat(logPath);
      const cap = 256 * 1024;
      const readLen = Math.min(cap, stat.size);
      const fh = await fs.open(logPath, "r");
      const { buffer, bytesRead } = await fh.read(
        Buffer.alloc(readLen), 0, readLen, Math.max(0, stat.size - readLen));
      await fh.close();
      const lines = buffer.toString("utf8", 0, bytesRead).split("\n");
      return ok(lines.slice(-Math.max(1, tail ?? 100)).join("\n"));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "triage_inbox",
  {
    description:
      "One-shot triage of untagged inbox reminders: a cheap classifier agent tags each as agent-work " +
      "or personal and routes agent work to a plan list. dry_run defaults to TRUE (reports proposed " +
      "changes, mutates nothing); pass dry_run: false to apply. Replaces the /loop triage pattern.",
    inputSchema: {
      inbox: z.string().optional().describe("Reminders list to triage (default: Reminders)."),
      agent: z
        .string()
        .optional()
        .describe('Classifier: an agents.json tag, or "local" for the on-device Apple model (macOS 26+).'),
      include_notes: z
        .boolean()
        .optional()
        .describe(
          "Also scan Apple Notes (shared watermark; advanced only when applying) and turn action items " +
          "into tasks/events with the source note's name for provenance."
        ),
      dry_run: z.boolean().optional().describe("Default true. Set false to apply tags/list moves."),
    },
    // Triage.TriageResult (Sources/AppleTasks/Triage.swift)
    outputSchema: {
      inbox: z.string(),
      untaggedCount: z.number().int(),
      applied: z.boolean(),
      actions: z.array(z.object({
        id: z.string(),
        title: z.string(),
        kind: z.string().describe('"agent" or "personal".'),
        addedTags: z.array(z.string()),
        movedTo: z.string().optional(),
        note: z.string().optional(),
      })),
      noteActions: z.array(z.object({
        source: z.string().describe("Source note name."),
        kind: z.string().describe('"task" or "event".'),
        title: z.string(),
        due: z.string().optional(),
        tags: z.array(z.string()),
        list: z.string().optional(),
        note: z.string().optional().describe("Skip/downgrade reason."),
      })).optional().describe("Present only when include_notes: true."),
    },
  },
  async ({ inbox, agent, include_notes, dry_run }) => {
    const args = ["triage"];
    if (inbox) args.push("--inbox", inbox);
    if (agent) args.push("--agent", agent);
    if (include_notes) args.push("--notes");
    if (dry_run === false) args.push("--apply");
    try {
      return okJson(await cli(args, 360_000)); // classifier spawn can take a minute
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "whereami",
  {
    description:
      "Get this Mac's current location (CoreLocation): lat/lon, accuracy, and reverse-geocoded place. " +
      "Use for location context (am I home? what city am I in?). First use needs a Location Services grant " +
      "for the MCP host process — run doctor if it times out.",
    inputSchema: {
      timeout: z.number().int().optional().describe("Seconds to wait for a fix (default 15)."),
      no_geocode: z.boolean().optional().describe("Skip reverse geocoding (coordinates only)."),
    },
    // WhereamiOut (Sources/AppleTasks/Location.swift)
    outputSchema: {
      latitude: z.number(),
      longitude: z.number(),
      accuracyMeters: z.number(),
      timestamp: z.string(),
      place: z.object({
        name: z.string().optional(),
        locality: z.string().optional(),
        administrativeArea: z.string().optional(),
        postalCode: z.string().optional(),
        country: z.string().optional(),
      }).optional().describe("Absent with no_geocode or when reverse geocoding fails."),
    },
  },
  async ({ timeout, no_geocode }) => {
    const args = ["whereami"];
    if (timeout !== undefined) args.push("--timeout", String(timeout));
    if (no_geocode) args.push("--no-geocode");
    try {
      return okJson(await cli(args));
    } catch (err) {
      return fail(err);
    }
  }
);

const FINDMY_SIDECAR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "../../sidecar/findmy-sidecar.py");
// Prefer the dedicated venv (created per sidecar setup docs), else system python.
const FINDMY_VENV_PYTHON = path.join(
  process.env.HOME ?? "", ".config/apple-tasks/findmy/venv/bin/python3");
const FINDMY_PYTHON =
  process.env.APPLE_TASKS_FINDMY_PYTHON ??
  ((await import("node:fs")).existsSync(FINDMY_VENV_PYTHON) ? FINDMY_VENV_PYTHON : "python3");

async function findmy(args: string[]): Promise<string> {
  // The sidecar prints a JSON {error, hint} object on failure (exit 1).
  try {
    const { stdout } = await execFileAsync(FINDMY_PYTHON, [FINDMY_SIDECAR, ...args], {
      timeout: 120_000,
    });
    return stdout.trim();
  } catch (err: any) {
    const detail = err.stdout?.trim() || err.stderr?.trim() || err.message;
    throw new Error(detail);
  }
}

server.registerTool(
  "findmy_devices",
  {
    description:
      "List Find My accessories configured for the FindMy.py sidecar (AirTags/OpenHaystack tags whose " +
      "pairing files are in ~/.config/apple-tasks/findmy/accessories/). Requires one-time interactive " +
      "setup: 'python3 sidecar/findmy-sidecar.py login'. Returns {error, hint} JSON when unconfigured.",
    inputSchema: {},
    // cmd_devices (sidecar/findmy-sidecar.py)
    outputSchema: {
      devices: z.array(z.object({
        name: z.string(),
        file: z.string(),
        identifier: z.string().nullable().optional(),
        serialNumber: z.string().nullable().optional(),
        model: z.string().nullable().optional(),
        error: z.string().optional().describe("Present when this accessory's pairing file failed to load."),
      })),
    },
  },
  async () => {
    try {
      return okJson(await findmy(["devices"]), "devices");
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "findmy_locate",
  {
    description:
      "Fetch the latest Find My network location report for a configured accessory by name " +
      "(see findmy_devices). Uses the owner's own Apple account via the FindMy.py sidecar; read-only.",
    inputSchema: {
      name: z.string().describe("Accessory name (file stem or pairing name)."),
    },
    // cmd_locate (sidecar/findmy-sidecar.py)
    outputSchema: {
      name: z.string(),
      latitude: z.number().nullable(),
      longitude: z.number().nullable(),
      timestamp: z.string().nullable(),
      confidence: z.number().nullable(),
      status: z.number().nullable(),
    },
  },
  async ({ name }) => {
    try {
      return okJson(await findmy(["locate", name]));
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "doctor",
  {
    description:
      "Diagnose apple-tasks setup for THIS host process: Reminders/Calendar permission status, " +
      "private native-tags helper availability, notes-scan watermark. TCC grants are per-host-process, " +
      "so run this when tools fail unexpectedly.",
    inputSchema: {},
    // DoctorOut (Sources/AppleTasks/Doctor.swift)
    outputSchema: {
      binary: z.string(),
      hostProcess: z.string(),
      reminders: z.string(),
      calendars: z.string(),
      location: z.string(),
      contacts: z.string(),
      foundationModels: z.string(),
      findmySidecar: z.string(),
      mailRule: z.string(),
      dropFolder: z.string(),
      privateHelper: z.object({
        present: z.boolean(),
        path: z.string().optional(),
        check: z.string().optional(),
      }),
      notesScanWatermark: z.string().optional(),
      speech: z.string(),
      fullDiskAccess: z.string(),
      automationNote: z.string(),
    },
  },
  async () => {
    try {
      return okJson(await cli(["doctor"]));
    } catch (err) {
      return fail(err);
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
