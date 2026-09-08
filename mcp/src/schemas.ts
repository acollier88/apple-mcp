import { z } from "zod";

export const tagsField = z
  .array(z.string())
  .optional()
  .describe("Tags (no spaces/brackets, e.g. 'claude', 'repo2'). Stored as [tag] prefixes on the reminder title.");

// ---- Output shapes. These mirror the JSON the Swift CLI emits (see the
// output structs in Sources/AppleTasks/*.swift); the MCP server adds no
// fields of its own. Swift's encodeIfPresent omits nil keys, hence .optional().

// TaskOut (Sources/AppleTasks/Support.swift)
export const taskShape = {
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
  attachments: z
    .array(z.object({
      kind: z.enum(["file", "image", "url", "other"]),
      uti: z.string().optional(),
      fileURL: z.string().optional().describe("Path in the Reminders store; reading the file needs Full Disk Access."),
      fileSize: z.number().int().optional(),
      url: z.string().optional(),
    }))
    .optional()
    .describe("task_show with attachments: true only."),
  attached: z.boolean().optional().describe("task_update attach_* only: whether the attach succeeded."),
  section: z.string().optional().describe("task_show with section: true only — the task's section name."),
  sectionApplied: z.boolean().optional().describe("task_update section only: whether the assign succeeded."),
};
export const taskSchema = z.object(taskShape);

// EventOut (Sources/AppleTasks/Support.swift)
export const eventShape = {
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
export const eventSchema = z.object(eventShape);

// ListOut / CalendarOut (Sources/AppleTasks/Support.swift)
export const listShape = { id: z.string(), name: z.string() };
export const calendarShape = { id: z.string(), name: z.string(), writable: z.boolean() };

// `delete` / `events delete` emit {"deleted": <id>}.
export const deletedShape = { deleted: z.string().describe("Id of the deleted item.") };

// SuggestionOut (Sources/AppleTasks/Suggest.swift)
export const suggestionSchema = z.object({
  kind: z.enum(["task", "event", "drop"]),
  title: z.string(),
  reason: z.string().describe("Why this is worth raising, citing the signal."),
  due: z.string().optional(),
});

// ContactOut (Sources/AppleTasks/Contacts.swift)
export const contactShape = {
  id: z.string(),
  name: z.string(),
  nickname: z.string().optional(),
  organization: z.string().optional(),
  emails: z.array(z.string()),
  phones: z.array(z.string()),
  birthday: z.string().optional().describe("yyyy-MM-dd, or MM-dd when the year is unknown."),
  postalAddresses: z.array(z.string()),
};

// WatchItemOut / WatchScan.Out (Sources/AppleTasks/Watches.swift)
export const watchItemShape = {
  watch: z.string().describe("Name of the watch that produced this item."),
  kind: z.enum(["rss", "url"]),
  ts: z.string().describe("Item timestamp (feed pubDate when parseable, else scan time), ISO8601."),
  title: z.string().optional(),
  url: z.string(),
  note: z.string().optional().describe("'content changed' for url watches; feed summary for rss."),
};

// MailHeaderOut / MailMessageOut (Sources/AppleTasks/Mail.swift)
export const mailHeaderShape = {
  id: z.string(),
  subject: z.string(),
  from: z.string(),
  received: z.string(),
  read: z.boolean(),
};

// GmailHeaderOut / GmailMessageOut (Sources/AppleTasks/Gmail.swift)
export const gmailHeaderShape = {
  id: z.string(),
  threadId: z.string(),
  subject: z.string(),
  from: z.string(),
  received: z.string(),
  read: z.boolean(),
};

// ApprovalOut (Sources/AppleTasks/Approvals.swift)
export const approvalShape = {
  token: z.string(),
  question: z.string(),
  taskId: z.string().optional(),
  status: z.enum(["pending", "approved", "denied", "expired"]),
  requestedAt: z.string(),
  expiresAt: z.string().optional(),
  answeredAt: z.string().optional(),
  answeredVia: z.string().optional().describe("'ntfy' (phone button), 'cli' (answered on the Mac), or 'timeout'."),
  pushSuppressed: z.string().optional().describe(
    "request only: quiet-hours window that held the push. The request still exists and is answerable."),
};
