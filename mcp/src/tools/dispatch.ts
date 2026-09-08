import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import path from "node:path";
import { cli, defineTool, fail, ok, okJson, trackTool } from "../lib";

export function registerDispatchTools(server: McpServer): void {
  const dispatchRunDescription =
    "Run the agent dispatcher: scan open [auto] tasks, launch configured agents, reap stale " +
    "runs, GC worktrees. A leading agent tag pins that lane; [auto] alone walks modelPrefs.auto " +
    "(any available worker). dry_run defaults to TRUE (reports what would run, launches nothing); a real run " +
    "(dry_run: false) spawns agent processes, waits for them, and consumes their session budgets. " +
    "reap_only reaps + GCs without dispatching.";
  const dispatchRunAnnotations = { title: "Run dispatcher", destructiveHint: true } as const;
  trackTool("dispatch_run", dispatchRunDescription, dispatchRunAnnotations);
  server.registerTool(
    "dispatch_run",
    {
      description: dispatchRunDescription,
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
      annotations: dispatchRunAnnotations,
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
        return okJson(
          await cli(args, { timeoutMs: dry_run !== false && !reap_only ? 30_000 : 7_200_000 }),
          (parsed) => ({ reports: parsed })
        );
      } catch (err) {
        return fail(err);
      }
    }
  );

  defineTool(server, {
    name: "dispatch_list",
    description:
      "Show the dispatch ledger: agent runs with status, exit code, outcome summary, run log path, worktree.",
    input: {
      status: z.enum(["running", "succeeded", "failed", "timeout", "cancelled", "aborted", "pending-review"]).optional(),
      limit: z.number().int().optional().describe("Max rows (default 50, newest first)."),
    },
    // AuditDB.DispatchRow | PendingReviewItem (Dispatch/PendingReview.swift)
    output: {
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
        branch: z.string().optional(),
        commitsAhead: z.number().int().optional(),
        commits: z.array(z.string()).optional(),
      })),
    },
    annotations: { title: "List dispatches", readOnlyHint: true },
    argv: ({ status, limit }) => {
      const args = ["dispatches"];
      if (status) args.push("--status", status);
      if (limit) args.push("--limit", String(limit));
      return args;
    },
    wrap: (parsed) => ({ dispatches: parsed }),
  });

  defineTool(server, {
    name: "dispatch_cancel",
    description:
      "Cancel a running dispatch by ledger id: signal the agent process (and its children), mark the " +
      "row 'cancelled', shed this Mac's [dispatched] claim. Does NOT write [failed], so no retry/backoff. " +
      "The worktree is left for GC. Returns {cancelled:false, note:'not running'} if the row already finished.",
    input: {
      ledger_id: z.number().int().describe("Ledger row id from dispatch_list (status running)."),
    },
    // DispatchCancel.Result | DispatchCancel.NotRunning (Dispatch/LedgerCommands.swift)
    output: {
      id: z.number().int(),
      status: z.string(),
      taskId: z.string().optional(),
      agent: z.string().optional(),
      process: z.string().optional().describe("terminated | killed | gone | not found"),
      tagShed: z.boolean().optional(),
      cancelled: z.boolean().optional(),
      note: z.string().optional(),
    },
    annotations: { title: "Cancel dispatch", destructiveHint: true, idempotentHint: true },
    timeoutMs: 30_000,
    argv: ({ ledger_id }) => ["dispatch-cancel", String(ledger_id)],
  });

  defineTool(server, {
    name: "dispatch_discard",
    description:
      "Discard a succeeded worktree branch by ledger id: force-remove the worktree, delete the " +
      "agent/<agent>-<id> branch, mark the row reviewed. Returns {discarded:false, note:'already reviewed'} " +
      "if the row was already reviewed.",
    input: {
      ledger_id: z.number().int().describe("Ledger row id from dispatch_list (status pending-review)."),
    },
    // DispatchDiscard.DiscardResult | DispatchDiscard.AlreadyReviewed
    output: {
      id: z.number().int(),
      branch: z.string().optional(),
      worktreeRemoved: z.boolean().optional(),
      branchDeleted: z.boolean().optional(),
      discarded: z.boolean().optional(),
      note: z.string().optional(),
    },
    annotations: { title: "Discard reviewed branch", destructiveHint: true, idempotentHint: true },
    timeoutMs: 60_000,
    argv: ({ ledger_id }) => ["dispatch-discard", String(ledger_id)],
  });

  const runLogDescription =
    "Read a dispatch run's captured agent output (~/.config/apple-tasks/runs/<ledger_id>.log). " +
    "Header lines record provider/model (and Cursor Auto's resolved model). " +
    "Returns the last `tail` lines (reads at most the final 256 KB).";
  const runLogAnnotations = { title: "Read run log", readOnlyHint: true } as const;
  trackTool("run_log", runLogDescription, runLogAnnotations);
  server.registerTool(
    "run_log",
    {
      // Raw agent output (arbitrary text lines) — no outputSchema.
      description: runLogDescription,
      inputSchema: {
        ledger_id: z.number().int().describe("Ledger row id from dispatch_list."),
        tail: z.number().int().optional().describe("Lines from the end (default 100)."),
      },
      annotations: runLogAnnotations,
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

  defineTool(server, {
    name: "triage_inbox",
    description:
      "One-shot triage of untagged inbox reminders: a cheap classifier agent tags each as agent-work " +
      "or personal and routes agent work to a plan list. dry_run defaults to TRUE (reports proposed " +
      "changes, mutates nothing); pass dry_run: false to apply. Replaces the /loop triage pattern.",
    input: {
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
    output: {
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
    annotations: { title: "Triage inbox", destructiveHint: true },
    timeoutMs: 360_000, // classifier spawn can take a minute
    argv: ({ inbox, agent, include_notes, dry_run }) => {
      const args = ["triage"];
      if (inbox) args.push("--inbox", inbox);
      if (agent) args.push("--agent", agent);
      if (include_notes) args.push("--notes");
      if (dry_run === false) args.push("--apply");
      return args;
    },
  });
}
