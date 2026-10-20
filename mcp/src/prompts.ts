import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

/**
 * Reusable operator prompts. Each one is the standing instruction the README
 * tells you to paste into an agent, kept here so hosts can offer them as
 * slash commands and so the wording lives in one place.
 */

function user(text: string) {
  return { messages: [{ role: "user" as const, content: { type: "text" as const, text } }] };
}

export function registerPrompts(server: McpServer): void {
  server.registerPrompt(
    "triage_inbox",
    {
      title: "Triage the Reminders inbox",
      description:
        "Classify untagged inbox reminders as agent work or personal and route them (the README /loop " +
        "triage rule, parameterized by inbox list). Prefer the one-shot triage_inbox tool; fall back to " +
        "manual task_update when a judgement needs context the classifier lacks.",
      argsSchema: {
        inbox: z.string().optional().describe("Reminders list to triage (default: Reminders)."),
        apply: z
          .enum(["true", "false"])
          .optional()
          .describe("'true' applies changes; default 'false' only reports the proposed routing."),
      },
    },
    ({ inbox, apply }) => {
      const list = inbox?.trim() || "Reminders";
      const applying = apply === "true";
      return user(
        [
          `Triage my Reminders inbox list "${list}".`,
          "",
          `1. Call triage_inbox(inbox: "${list}", dry_run: ${applying ? "false" : "true"}) and read the actions.`,
          "2. For anything it left unrouted or judged wrongly, look at the task with task_show and decide yourself:",
          "   - Actionable agent work → task_update: add the agent tag ([claude], [cursor], …) or just [auto] to let",
          "     the dispatcher pick any available worker, add a workdir tag if it needs a repo (see plan_list and the",
          "     apple-tasks://config/agents resource for lanes and workdirs), and move it to the right plan list.",
          "   - Personal → task_update: add [personal] and leave it where it is.",
          "3. Never touch tasks that already have tags. Never complete or delete anything.",
          applying
            ? "4. Report what changed as a short list: title → tags, list."
            : "4. This is a dry run: report the proposed routing and stop; do not call task_update.",
        ].join("\n")
      );
    }
  );

  server.registerPrompt(
    "morning_digest",
    {
      title: "Morning digest",
      description:
        "Summarize what the agents did overnight and what is on deck today, from the digest tool plus " +
        "the pending-review ledger. Deterministic inputs; the model only narrates.",
      argsSchema: {},
    },
    () =>
      user(
        [
          "Give me my morning agent digest.",
          "",
          "1. Call digest() (no note, no push) — it returns agent activity since yesterday, dispatch outcomes,",
          "   tasks due today, and today's calendar.",
          '2. Call dispatch_list(status: "pending-review") for branches awaiting my review, and',
          '   dispatch_list(status: "failed", limit: 10) for anything that needs re-driving.',
          "3. Write ≤12 lines: outcomes (succeeded/failed/cancelled counts with the notable titles), branches to",
          "   review with their commit counts, failures with a one-line cause from run_log if the trailer is",
          "   unclear, then what's due today and the calendar load. Link PR URLs where tasks carry them.",
          "4. Do not create, complete, or dispatch anything.",
        ].join("\n")
      )
  );

  server.registerPrompt(
    "supervisor_loop",
    {
      title: "Supervisor pass",
      description:
        "One pass of the dispatcher supervisor: reap stale runs, inspect failures, decide retry vs cancel, " +
        "and notify. Designed for /loop or a scheduled agent; never launches agents itself.",
      argsSchema: {
        notify: z
          .enum(["true", "false"])
          .optional()
          .describe("'true' sends a one-line notify(push: true) summary when something changed (default 'false')."),
      },
    },
    ({ notify }) =>
      user(
        [
          "Run one supervisor pass over the apple-tasks dispatcher.",
          "",
          "1. dispatch_run(reap_only: true) — reap stale running rows and GC worktrees. Read the reports.",
          '2. dispatch_list(status: "running") — for each row older than its lane timeout (see the',
          "   apple-tasks://config/agents resource), read run_log(ledger_id, tail: 40). If the log is quiet and the",
          "   task is stuck, dispatch_cancel(ledger_id). Otherwise leave it.",
          '3. dispatch_list(status: "failed", limit: 20) — for each recent failure read the run log tail and classify:',
          "   - transient (rate limit, network, timeout at the edge) → task_update(remove_tags: [\"failed\"]) so the",
          "     next pass retries; do this at most once per task (check the notes trailers for prior retries);",
          "   - needs a human (bad task, missing permission, wrong repo) → task_update(append_notes: <one-line",
          "     diagnosis>) and leave [failed] on;",
          "   - already fixed upstream → task_complete(id).",
          '4. dispatch_list(status: "pending-review") — list branches awaiting review; do NOT discard any.',
          "5. Do not call dispatch_run with dry_run: false; launching agents is launchd's job.",
          notify === "true"
            ? "6. If you cancelled, retried, or annotated anything, notify(title: \"Supervisor\", body: <one line>, push: true)."
            : "6. Finish with a ≤8-line summary of what you did and what needs me.",
        ].join("\n")
      )
  );

  server.registerPrompt(
    "task_writer",
    {
      title: "Write a dispatchable task",
      description:
        "How to phrase a task so the dispatcher can run it unattended: tags for lane/workdir, [auto], " +
        "due = run-at, notes as the agent's brief. Produces a task_create call.",
      argsSchema: {
        goal: z.string().describe("What should get done, in your own words."),
        list: z.string().optional().describe("Plan (Reminders list) to file it in; default: ask plan_list."),
      },
    },
    ({ goal, list }) =>
      user(
        [
          `Turn this into a task the apple-tasks dispatcher can run unattended: "${goal}"`,
          "",
          "Rules for a dispatchable task:",
          "- Title: imperative, one line, no tag brackets in the text itself (tags go in the tags array).",
          "- tags: include \"auto\" so the dispatcher picks it up. Add a lane tag (claude, cursor, …) only to pin a",
          "  provider; otherwise [auto] alone lets modelPrefs.auto choose any available worker. Add the workdir",
          "  tag for the repo it touches (lanes and workdirs: apple-tasks://config/agents). Classifier/ops lanes",
          "  (triage, local, doctor, heal) are not for user work.",
          "- notes: the agent's brief — acceptance criteria, files or URLs to start from, what NOT to do, and how",
          "  to report (the agent appends an outcome and calls task_complete when done). Keep it under ~30 lines.",
          "- due: the run-at time. A task with no due date runs on the next pass; a future due date queues it.",
          "  For standing work add recurrence (FREQ=DAILY, FREQ=WEEKLY;BYDAY=MO, …).",
          "- priority: high only if it should jump the queue.",
          "- url: a PR/issue/doc link if one exists.",
          "",
          list
            ? `File it in the "${list}" list.`
            : "Call plan_list and pick the list whose name matches the repo or theme; ask me if none fits.",
          "Show me the task_create call you intend to make, then make it.",
        ].join("\n")
      )
  );
}
