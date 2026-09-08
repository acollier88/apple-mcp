import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";
import { deletedShape, tagsField, taskSchema, taskShape, listShape } from "../schemas";

export function registerTaskTools(server: McpServer): void {
  defineTool(server, {
    name: "task_list",
    description:
      "List tasks from Apple Reminders. Filter by list (plan), tags (AND), and status. Returns JSON tasks with parsed tags.",
    input: {
      list: z.string().optional().describe("Reminders list name (a plan). Omit for all lists."),
      tags: tagsField,
      status: z.enum(["open", "completed", "all"]).optional().describe("Default: open."),
      due_before: z
        .string()
        .optional()
        .describe("Only tasks due before this date (yyyy-MM-dd inclusive of that day, 'yyyy-MM-dd HH:mm', or ISO8601). Undated tasks are excluded."),
      overdue: z.boolean().optional().describe("Only tasks whose due date has passed (excludes undated tasks)."),
      search: z.string().optional().describe("Case-insensitive substring match over title and notes."),
    },
    output: { tasks: z.array(taskSchema) },
    annotations: { title: "List tasks", readOnlyHint: true },
    argv: ({ list, tags, status, due_before, overdue, search }) => {
      const args = ["list"];
      if (list) args.push("--list", list);
      for (const t of tags ?? []) args.push("--tag", t);
      if (status) args.push("--status", status);
      if (due_before) args.push("--due-before", due_before);
      if (overdue) args.push("--overdue");
      if (search) args.push("--search", search);
      return args;
    },
    wrap: (parsed) => ({ tasks: parsed }),
  });

  defineTool(server, {
    name: "task_create",
    description:
      "Create a task in a Reminders list. Tags become a [tag] prefix on the title (e.g. '[claude][repo2] Add MFA').",
    input: {
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
    output: taskShape,
    annotations: { title: "Create task", destructiveHint: false },
    argv: ({ list, title, tags, notes, due, priority, url, recurrence }) => {
      const args = ["add", "--list", list];
      for (const t of tags ?? []) args.push("--tag", t);
      if (notes) args.push("--notes", notes);
      if (due) args.push("--due", due);
      if (priority) args.push("--priority", priority);
      if (url) args.push("--url", url);
      if (recurrence) args.push("--recurrence", recurrence);
      args.push(title);
      return args;
    },
  });

  defineTool(server, {
    name: "task_create_batch",
    description:
      "Create several tasks in one call (e.g. a whole triage run). Items are processed independently: " +
      "failures are reported per-item under `failed` and never abort the rest of the batch.",
    input: {
      items: z
        .array(
          z.object({
            list: z.string().describe("Reminders list name to create the task in (required)."),
            title: z.string().describe("Task title, without tag prefix."),
            tags: tagsField,
            notes: z.string().optional(),
            due: z.string().optional().describe("yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601."),
            priority: z.enum(["none", "low", "medium", "high"]).optional(),
            url: z.string().optional().describe("URL to attach (PR/artifact links)."),
            recurrence: z.string().optional().describe("Repeat rule, requires due. Same RRULE subset as task_create."),
          })
        )
        .min(1)
        .describe("Tasks to create, in order."),
    },
    output: {
      created: z.array(taskSchema),
      failed: z.array(
        z.object({
          index: z.number().int().describe("Index into the submitted items array."),
          title: z.string(),
          error: z.string(),
        })
      ),
    },
    annotations: { title: "Create tasks", destructiveHint: false },
    argv: () => ["add-batch"],
    stdin: ({ items }) => JSON.stringify(items),
  });

  defineTool(server, {
    name: "task_update",
    description: "Update a task: retitle, add/remove tags, notes, due date, priority, or move to another list.",
    input: {
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
      attach_file: z.string().optional().describe("Attach a file by absolute path (copied into the Reminders store)."),
      attach_url: z.string().optional().describe("Attach a URL as a rich attachment (distinct from the url field)."),
      clear_parent: z.boolean().optional().describe("Detach from the parent task (stays in its list)."),
      section: z.string().optional().describe("Move into this section of the task's list, creating it if needed."),
    },
    output: taskShape,
    annotations: { title: "Update task", idempotentHint: true },
    argv: ({
      id,
      title,
      add_tags,
      remove_tags,
      notes,
      append_notes,
      due,
      clear_due,
      priority,
      list,
      url,
      clear_url,
      parent,
      recurrence,
      clear_recurrence,
      attach_file,
      attach_url,
      clear_parent,
      section,
    }) => {
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
      if (attach_file) args.push("--attach-file", attach_file);
      if (attach_url) args.push("--attach-url", attach_url);
      if (clear_parent) args.push("--clear-parent");
      if (section) args.push("--section", section);
      return args;
    },
  });

  defineTool(server, {
    name: "task_complete",
    description:
      "Mark a task completed. Recurring tasks roll to their next occurrence instead (response has recurred=true, completed=false, and the next due date).",
    input: { id: z.string() },
    output: taskShape,
    annotations: { title: "Complete task", idempotentHint: true },
    argv: ({ id }) => ["complete", id],
  });

  defineTool(server, {
    name: "task_delete",
    description: "Delete a task permanently.",
    input: { id: z.string() },
    output: deletedShape,
    annotations: { title: "Delete task", destructiveHint: true },
    argv: ({ id }) => ["delete", id],
  });

  defineTool(server, {
    name: "plan_list",
    description: "List Reminders lists. Each list is a plan; its reminders are the plan's tasks.",
    input: {},
    output: { plans: z.array(z.object(listShape)) },
    annotations: { title: "List plans", readOnlyHint: true },
    argv: () => ["lists"],
    wrap: (parsed) => ({ plans: parsed }),
  });

  defineTool(server, {
    name: "plan_create",
    description: "Create a new Reminders list to serve as a plan.",
    input: { name: z.string().describe("Name for the new list/plan.") },
    output: listShape,
    annotations: { title: "Create plan", destructiveHint: false },
    argv: ({ name }) => ["lists", "add", name],
  });

  defineTool(server, {
    name: "task_show",
    description: "Show a single task by id: full JSON including notes (with dispatch trailers) and tags.",
    input: {
      id: z.string().describe("Task id from task_list/dispatch_list."),
      attachments: z.boolean().optional().describe(
        "Include attachments (kind/uti/fileURL/url). Reading a fileURL's content needs Full Disk Access."),
      section: z.boolean().optional().describe("Include the task's section name."),
    },
    output: taskShape,
    annotations: { title: "Show task", readOnlyHint: true },
    argv: ({ id, attachments, section }) => {
      const args = ["show", id];
      if (attachments) args.push("--attachments");
      if (section) args.push("--section");
      return args;
    },
  });

  defineTool(server, {
    name: "task_uncomplete",
    description: "Mark a completed task open again.",
    input: { id: z.string().describe("Task id.") },
    output: taskShape,
    annotations: { title: "Uncomplete task", idempotentHint: true },
    argv: ({ id }) => ["uncomplete", id],
  });
}
