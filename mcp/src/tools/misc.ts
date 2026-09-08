import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { cli, defineTool, fail, ok, okJson, trackTool } from "../lib";
import { eventSchema, suggestionSchema, tagsField, taskSchema } from "../schemas";

const execFileAsync = promisify(execFile);

const FINDMY_SIDECAR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "../../../tools/findmy/findmy-sidecar.py");
// Prefer the dedicated venv (created per sidecar setup docs), else system python.
const FINDMY_VENV_PYTHON = path.join(
  process.env.HOME ?? "", ".config/apple-tasks/findmy/venv/bin/python3");
const FINDMY_PYTHON =
  process.env.APPLE_TASKS_FINDMY_PYTHON ??
  (existsSync(FINDMY_VENV_PYTHON) ? FINDMY_VENV_PYTHON : "python3");

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

export function registerMiscTools(server: McpServer): void {
  const digestDescription =
    "Morning digest: agent activity since yesterday (audit log), dispatch outcomes, tasks due today, " +
    "and today's calendar, as one JSON blob. Optionally writes it as a new Apple Note (note: true) " +
    "and/or pushes a one-line summary to the configured ntfy topic (push: true).";
  const digestAnnotations = { title: "Digest", openWorldHint: true } as const;
  trackTool("digest", digestDescription, digestAnnotations);
  server.registerTool(
    "digest",
    {
      description: digestDescription,
      inputSchema: {
        since: z.string().optional().describe("Look-back start (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601; default 24h ago)."),
        note: z.boolean().optional().describe("Write the digest as a new Apple Note."),
        note_folder: z.string().optional().describe("Notes folder for the digest note."),
        push: z.boolean().optional().describe("Send a short summary to the configured ntfy topic."),
        suggest: z.boolean().optional().describe("Append on-device model proposals (never auto-created)."),
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
        suggestions: z.array(suggestionSchema).optional().describe("suggest: true only — proposals, never applied."),
        suggestError: z.string().optional().describe("suggest: true only — why proposals were unavailable."),
      },
      annotations: digestAnnotations,
    },
    async ({ since, note, note_folder, push, suggest }) => {
      const args = ["digest"];
      if (since) args.push("--since", since);
      if (note) args.push("--note");
      if (note_folder) args.push("--note-folder", note_folder);
      if (push) args.push("--push");
      if (suggest) args.push("--suggest");
      try {
        return okJson(await cli(args, { timeoutMs: suggest ? 180_000 : 60_000 }));
      } catch (err) {
        return fail(err);
      }
    }
  );

  defineTool(server, {
    name: "suggest",
    description:
      "Proactive suggestions: reviews the next week's calendar, upcoming " +
      "birthdays, stale tasks, and recent agent activity, and PROPOSES tasks/events/drops. Nothing is " +
      "ever created — apply accepted proposals yourself via task_create/event_create.",
    input: {
      days: z.number().int().optional().describe("Calendar look-ahead in days (default 7)."),
      stale_weeks: z.number().int().optional().describe("Open [read]/claimed/overdue tasks older than this count as stale (default 4)."),
      max: z.number().int().optional().describe("Suggestion cap (default 8)."),
      no_contacts: z.boolean().optional().describe("Skip the birthday feed (no Contacts prompt)."),
      agent: z.string().optional().describe("Model seat: 'local' (on-device Apple model) or an agents.json lane (CLI or BYOM llm). Default: agents.json suggest.agent, else local."),
    },
    // SuggestOut (Sources/AppleTasks/Suggest.swift)
    output: {
      generatedAt: z.string(),
      inputs: z.object({
        events: z.number().int(),
        birthdays: z.number().int(),
        staleTasks: z.number().int(),
        auditActions: z.number().int(),
        contactsNote: z.string().optional(),
      }),
      suggestions: z.array(suggestionSchema),
    },
    annotations: { title: "Suggest", readOnlyHint: true },
    timeoutMs: 180_000,
    argv: ({ days, stale_weeks, max, no_contacts, agent }) => {
      const args = ["suggest"];
      if (days !== undefined) args.push("--days", String(days));
      if (stale_weeks !== undefined) args.push("--stale-weeks", String(stale_weeks));
      if (max !== undefined) args.push("--max", String(max));
      if (no_contacts) args.push("--no-contacts");
      if (agent) args.push("--agent", agent);
      return args;
    },
  });

  defineTool(server, {
    name: "github_sync",
    description:
      "Two-way GitHub issue sync via the gh CLI: assigned open issues become [github]-tagged tasks " +
      "(issue URL = dedupe key), closed issues complete their reminders, and completed reminders close " +
      "their issues only when close_issues is true. dry_run defaults TRUE from MCP — pass dry_run: false " +
      "to apply.",
    input: {
      repo: z.string().describe("GitHub repository, owner/repo."),
      list: z.string().optional().describe("Reminders list for created tasks (default \"Code Tasks\")."),
      tags: tagsField,
      assignee: z.string().optional().describe("Issue assignee filter for gh (default @me; \"all\" disables)."),
      limit: z.number().int().optional().describe("Max issues fetched (default 50)."),
      close_issues: z.boolean().optional().describe("Close GitHub issues whose reminders are completed (outbound writes; default false)."),
      dry_run: z.boolean().optional().describe("Default TRUE from MCP: report without changing anything."),
    },
    // GitHubSyncOut (Sources/AppleTasks/GitHubSync.swift)
    output: {
      repo: z.string(),
      issuesSeen: z.number().int(),
      created: z.array(taskSchema),
      completedReminders: z.array(z.string()),
      closedIssues: z.array(z.string()),
      wouldCloseIssues: z.array(z.string()).describe("Completed reminders' open issues; rerun with close_issues to close."),
      unchanged: z.number().int(),
      dryRun: z.boolean(),
    },
    annotations: { title: "Sync GitHub", destructiveHint: true, openWorldHint: true },
    timeoutMs: 120_000,
    argv: ({ repo, list, tags, assignee, limit, close_issues, dry_run }) => {
      const args = ["sync-github", "--repo", repo];
      if (list) args.push("--list", list);
      for (const t of tags ?? []) args.push("--tag", t);
      if (assignee) args.push("--assignee", assignee);
      if (limit !== undefined) args.push("--limit", String(limit));
      if (close_issues) args.push("--close-issues");
      if (dry_run !== false) args.push("--dry-run");
      return args;
    },
  });

  const shortcutListDescription =
    "List the names of all Shortcuts available on this Mac (via the macOS 'shortcuts' CLI).";
  const shortcutListAnnotations = { title: "List shortcuts", readOnlyHint: true } as const;
  trackTool("shortcut_list", shortcutListDescription, shortcutListAnnotations);
  server.registerTool(
    "shortcut_list",
    {
      // Plain text from the macOS 'shortcuts' CLI (one name per line) — no
      // structured output to declare.
      description: shortcutListDescription,
      inputSchema: {},
      annotations: shortcutListAnnotations,
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

  const shortcutRunDescription =
    "Run a macOS Shortcut by name, optionally passing text input, and return its text output. " +
    "Escape hatch to anything Shortcuts can do: HomeKit, Focus modes, notifications, etc.";
  const shortcutRunAnnotations = { title: "Run shortcut", destructiveHint: true } as const;
  trackTool("shortcut_run", shortcutRunDescription, shortcutRunAnnotations);
  server.registerTool(
    "shortcut_run",
    {
      // Output is whatever the shortcut prints — genuinely free-form text, so
      // no outputSchema.
      description: shortcutRunDescription,
      inputSchema: {
        name: z.string().describe("Exact shortcut name (see shortcut_list)."),
        input: z.string().optional().describe("Text passed to the shortcut as input."),
      },
      annotations: shortcutRunAnnotations,
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

  defineTool(server, {
    name: "notify",
    description:
      "Show a local macOS notification banner (e.g. to report a finished task). " +
      "push: true also sends it via ntfy so it reaches the user's phone off-Mac " +
      "(requires ~/.config/apple-tasks/notify.json). Respects the config's quietHours " +
      "window (suppressed but still succeeds); force: true overrides for priority pings.",
    input: {
      title: z.string(),
      message: z.string(),
      sound: z.boolean().optional().describe("Play the default notification sound."),
      push: z.boolean().optional().describe("Also push via ntfy."),
      force: z.boolean().optional().describe("Send even during quiet hours."),
    },
    // NotifyCommand.Out (Sources/AppleTasks/Notify.swift). Everything goes
    // through the CLI so quiet hours apply uniformly (an earlier version
    // showed banners via osascript directly, bypassing them).
    output: {
      banner: z.boolean(),
      pushed: z.boolean(),
      suppressedQuietHours: z.string().optional().describe("Window that suppressed this notification, when it did."),
    },
    annotations: { title: "Send notification", openWorldHint: true },
    argv: ({ title, message, sound, push, force }) => {
      const args = ["notify", title, message];
      if (sound) args.push("--sound");
      if (push) args.push("--push");
      if (force) args.push("--force");
      return args;
    },
  });

  defineTool(server, {
    name: "audit_log",
    description:
      "Read the apple-tasks audit log: every mutation (task/event create/update/complete/delete, dispatches) " +
      "with timestamp and caller (mcp/app/dispatcher/terminal). Use to check 'did I already do this?' before acting.",
    input: {
      since: z.string().optional().describe("ISO8601 or yyyy-MM-dd lower bound."),
      task: z.string().optional().describe("Only entries for this task id."),
      caller: z.string().optional().describe("Caller substring filter (mcp, agent:claude, ...)."),
      limit: z.number().int().optional().describe("Max rows, newest first (default 50)."),
    },
    // AuditDB.AuditRow (Sources/AppleTasks/Audit.swift)
    output: {
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
    annotations: { title: "Read audit log", readOnlyHint: true },
    argv: ({ since, task, caller, limit }) => {
      const args = ["log"];
      if (since) args.push("--since", since);
      if (task) args.push("--task", task);
      if (caller) args.push("--caller", caller);
      if (limit !== undefined) args.push("--limit", String(limit));
      return args;
    },
    wrap: (parsed) => ({ entries: parsed }),
  });

  defineTool(server, {
    name: "whereami",
    description:
      "Get this Mac's current location (CoreLocation): lat/lon, accuracy, and reverse-geocoded place. " +
      "Use for location context (am I home? what city am I in?). First use needs a Location Services grant " +
      "for the MCP host process — run doctor if it times out.",
    input: {
      timeout: z.number().int().optional().describe("Seconds to wait for a fix (default 15)."),
      no_geocode: z.boolean().optional().describe("Skip reverse geocoding (coordinates only)."),
    },
    // WhereamiOut (Sources/AppleTasks/Location.swift)
    output: {
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
    annotations: { title: "Where am I", readOnlyHint: true },
    argv: ({ timeout, no_geocode }) => {
      const args = ["whereami"];
      if (timeout !== undefined) args.push("--timeout", String(timeout));
      if (no_geocode) args.push("--no-geocode");
      return args;
    },
  });

  const findmyDevicesDescription =
    "List Find My accessories configured for the FindMy.py sidecar (AirTags/OpenHaystack tags whose " +
    "pairing files are in ~/.config/apple-tasks/findmy/accessories/). Requires one-time interactive " +
    "setup: 'python3 tools/findmy/findmy-sidecar.py login'. Returns {error, hint} JSON when unconfigured.";
  const findmyDevicesAnnotations = {
    title: "List Find My devices",
    readOnlyHint: true,
    openWorldHint: true,
  } as const;
  trackTool("findmy_devices", findmyDevicesDescription, findmyDevicesAnnotations);
  server.registerTool(
    "findmy_devices",
    {
      description: findmyDevicesDescription,
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
      annotations: findmyDevicesAnnotations,
    },
    async () => {
      try {
        return okJson(await findmy(["devices"]), (parsed) => ({ devices: parsed }));
      } catch (err) {
        return fail(err);
      }
    }
  );

  const findmyLocateDescription =
    "Fetch the latest Find My network location report for a configured accessory by name " +
    "(see findmy_devices). Uses the owner's own Apple account via the FindMy.py sidecar; read-only.";
  const findmyLocateAnnotations = {
    title: "Locate Find My device",
    readOnlyHint: true,
    openWorldHint: true,
  } as const;
  trackTool("findmy_locate", findmyLocateDescription, findmyLocateAnnotations);
  server.registerTool(
    "findmy_locate",
    {
      description: findmyLocateDescription,
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
      annotations: findmyLocateAnnotations,
    },
    async ({ name }) => {
      try {
        return okJson(await findmy(["locate", name]));
      } catch (err) {
        return fail(err);
      }
    }
  );

  const doctorDescription =
    "Diagnose apple-tasks setup for THIS host process: Reminders/Calendar permission status, " +
    "dispatcher config, independent Hermes vs Home Assistant healthchecks, Budget Tracker bandwidth, " +
    "structured issues[], and optional --enqueue-heals (creates [heal][auto] tasks for unhealthy systems; " +
    "launchd dispatch picks them up — this tool does not spawn agents). TCC grants are per-host-process.";
  // Not readOnly: enqueue_heals creates [heal][auto] reminders.
  const doctorAnnotations = { title: "Doctor", readOnlyHint: false, destructiveHint: false, idempotentHint: true } as const;
  trackTool("doctor", doctorDescription, doctorAnnotations);
  server.registerTool(
    "doctor",
    {
      description: doctorDescription,
      inputSchema: {
        enqueue_heals: z
          .boolean()
          .optional()
          .describe("If true, create one [heal][auto] task per unhealthy system (deduped). Does not dispatch."),
        list: z
          .string()
          .optional()
          .describe("Reminders list for heal tasks (default: Code Tasks). Only used with enqueue_heals."),
      },
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
        agentsConfig: z.string(),
        cursorAgent: z.string(),
        launchAgent: z.string(),
        hermes: z.string(),
        hermesGateway: z.string(),
        hermesCron: z.string(),
        hermesHaLink: z.string(),
        homeAssistant: z.string(),
        budget: z.string(),
        automationNote: z.string(),
        issues: z.array(
          z.object({
            system: z.string(),
            severity: z.string(),
            summary: z.string(),
            signature: z.string(),
          })
        ),
        heals: z
          .object({
            list: z.string(),
            actions: z.array(
              z.object({
                system: z.string(),
                action: z.string(),
                taskId: z.string().nullable().optional(),
                title: z.string().nullable().optional(),
                reason: z.string().nullable().optional(),
              })
            ),
          })
          .nullable()
          .optional(),
      },
      annotations: doctorAnnotations,
    },
    async ({ enqueue_heals, list }) => {
      try {
        const args = ["doctor"];
        if (enqueue_heals) args.push("--enqueue-heals");
        if (list) args.push("--list", list);
        return okJson(await cli(args, { timeoutMs: enqueue_heals ? 60_000 : 30_000 }));
      } catch (err) {
        return fail(err);
      }
    }
  );
}
