import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";
import { calendarShape, deletedShape, eventSchema, eventShape, tagsField } from "../schemas";

export function registerCalendarTools(server: McpServer): void {
  defineTool(server, {
    name: "event_list",
    description:
      "List Calendar events in a date range (default: today through +7 days). Filter by calendar and tags (AND). Same [tag] title convention as tasks.",
    input: {
      calendar: z.string().optional().describe("Calendar name. Omit for all calendars."),
      tags: tagsField,
      from: z.string().optional().describe("Range start: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Default: start of today."),
      to: z.string().optional().describe("Range end, same formats. Default: from + 7 days."),
    },
    output: { events: z.array(eventSchema) },
    annotations: { title: "List events", readOnlyHint: true },
    argv: ({ calendar, tags, from, to }) => {
      const args = ["events", "list"];
      if (calendar) args.push("--calendar", calendar);
      for (const t of tags ?? []) args.push("--tag", t);
      if (from) args.push("--from", from);
      if (to) args.push("--to", to);
      return args;
    },
    wrap: (parsed) => ({ events: parsed }),
  });

  defineTool(server, {
    name: "event_show",
    description: "Show a single Calendar event by id.",
    input: { id: z.string().describe("Event id from event_list/event_create.") },
    output: eventShape,
    annotations: { title: "Show event", readOnlyHint: true },
    argv: ({ id }) => ["events", "show", id],
  });

  defineTool(server, {
    name: "event_create",
    description:
      "Create a Calendar event. A date-only start (yyyy-MM-dd) makes an all-day event. Tags become a [tag] title prefix.",
    input: {
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
    output: eventShape,
    annotations: { title: "Create event", destructiveHint: false },
    argv: ({ calendar, title, tags, start, end, duration, location, notes, url, recurrence }) => {
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
      return args;
    },
  });

  defineTool(server, {
    name: "event_update",
    description: "Update a Calendar event: retitle, add/remove tags, retime, location, notes, or move calendars.",
    input: {
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
    output: eventShape,
    annotations: { title: "Update event", idempotentHint: true },
    argv: ({ id, title, add_tags, remove_tags, start, end, location, notes, calendar, url, clear_url }) => {
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
      return args;
    },
  });

  defineTool(server, {
    name: "event_delete",
    description: "Delete a Calendar event permanently.",
    input: { id: z.string() },
    output: deletedShape,
    annotations: { title: "Delete event", destructiveHint: true },
    argv: ({ id }) => ["events", "delete", id],
  });

  defineTool(server, {
    name: "calendar_list",
    description: "List Calendar calendars with writability.",
    input: {},
    output: { calendars: z.array(z.object(calendarShape)) },
    annotations: { title: "List calendars", readOnlyHint: true },
    argv: () => ["calendars"],
    wrap: (parsed) => ({ calendars: parsed }),
  });
}
