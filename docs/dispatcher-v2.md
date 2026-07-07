# Dispatcher v2 — architecture

Design for evolving `apple-tasks dispatch` (Sources/AppleTasks/Dispatch.swift)
from the v1 sequential loop to a concurrent, result-aware dispatcher. Grounded
in a read of v1 as of 2026-07-07; line references are to that revision.

## What v1 already does (don't rebuild)

- Dedupe: `[dispatched]` tag + `hasActiveDispatch` ledger check (Dispatch.swift:169,184)
- Retry: `[failed]` tag + `maxRetries` + linear backoff via `failedAttempts` (171–182)
- Reap: `running` rows older than `--reap-hours` → `timeout` + `[failed]` (138–151)
- Isolation: per-run git worktree + branch `agent/<tag>-<ledgerId>` (226–252)
- Observability: per-run log file, ledger paths, audit rows (254–265)
- Timeout: poll + SIGTERM→SIGKILL escalation (281–295)

## Gap 1 — concurrency (the "v1 runs sequentially" line)

One long agent run blocks every other task. Change the per-reminder body
(160–315) into a `TaskGroup` with a cap:

```
agents.json: { "maxConcurrent": 3, "agents": { "claude": { "maxConcurrent": 1, … } } }
```

- Global cap via `withThrowingTaskGroup` + a counting semaphore; per-agent cap
  checked before enqueue (an agent whose slots are full is skipped this pass —
  the next dispatch run picks it up; no in-process queueing to reason about).
- **Phase separation is mandatory**: EventKit (`EKReminder`, `Store`) is not
  Sendable-safe for concurrent mutation. Phase A (serial, main actor): scan
  reminders, filter candidates, save `[dispatched]` tags, insert ledger rows,
  render prompts → emit an array of plain-value `RunSpec` structs (argv, cwd,
  worktree flag, ledgerId, taskId, timeout). Phase B (task group): spawn
  processes from `RunSpec`s only — no EventKit objects cross the boundary.
  Phase C (serial, after group): tag write-backs (`markFailed`, result notes)
  re-fetch reminders one at a time, exactly as `markFailed` does today (321).

## Gap 2 — atomic claim (double-dispatch race)

Two dispatchers (cron + manual, or two Macs) can both pass the
`hasActiveDispatch` check (184) before either inserts its ledger row.
Fix in AuditDB: make claim a single SQLite statement —

```sql
INSERT INTO dispatches (task_id, agent, status, …)
SELECT ?, ?, 'running', …
WHERE NOT EXISTS (SELECT 1 FROM dispatches WHERE task_id = ? AND status = 'running');
```

`changes() == 0` → someone else holds the claim; skip silently. The
`[dispatched]` tag write moves AFTER the claim succeeds (today it's before,
217 vs 218 — a crash between the two strands the tag; post-claim ordering
makes the reaper the only tag-fixer needed). The tag stays as the
human-visible mirror; the ledger row becomes the source of truth.

## Gap 3 — result contract (write-back)

v1 infers success from exit code; the task itself learns nothing. Define:

- **Agent side** (prompt template addition): "When done, write a 1–3 sentence
  outcome summary: `apple-tasks update {id} --notes-append '<summary>'`" plus
  the existing complete/untag instructions. Convention over protocol — no new
  IPC, works for any CLI agent.
- **Dispatcher side** (Phase C, always runs): append a structured trailer to
  the task notes on finish:
  `[dispatch #<ledgerId>] <status> exit=<code> branch=<branch> log=<path>`
  and, on `worktree` runs that succeeded, the branch name is the deliverable —
  include `git -C <repo> log --oneline <base>..<branch> | head -3` in the
  trailer so the task shows what was produced.
- Ledger gains a `summary` column (first line of trailer) so `dispatches`
  output answers "what happened" without opening Reminders.
- Failure semantics unchanged: `[failed]` tag + retry policy. `succeeded` but
  task left uncompleted = agent chose not to complete it; dispatcher does NOT
  auto-complete (the agent may have legitimately partial-finished).

## Gap 4 — worktree lifecycle

Worktrees accumulate forever under `~/.config/apple-tasks/worktrees/<ledgerId>`.
Policy, run during reap phase:

- `failed`/`timeout` runs: keep worktree `keepFailedWorktreeDays` (default 7),
  then `git worktree remove --force` + delete branch if unmerged-and-empty.
- `succeeded` runs: if branch is fully merged into the base branch → remove
  worktree + branch immediately; if unmerged → keep (it IS the deliverable),
  surface in `dispatches` as `unmerged branch pending`.
- New `dispatch --gc` flag (implied by default run, like reap) so cleanup
  needs no separate cron entry.

## Gap 5 — notify

On each Phase C finish: fire the existing notify path (osascript
notification) with title = task title, body = trailer summary. Config gate
`notifyOn: "failure" | "all" | "none"` (default `failure`).

## Non-goals (v2)

- No daemon/watch mode — dispatch stays a one-shot scan invoked by cron,
  `/loop`, or by hand. (Idea #8's morning digest reads the same ledger.)
- No cross-machine coordination beyond the SQLite claim (ledger DB is
  per-Mac; two Macs dispatching the same iCloud list is out of scope, the
  `[dispatched]` tag is the only cross-device signal and it's eventually
  consistent at Reminders-sync speed).
- No structured agent IPC (JSON result files etc.) — notes-append convention
  first; revisit only if it proves lossy.

## Build order

1. ✅ Atomic claim in AuditDB + move tag-write post-claim (2026-07-07; claim
   SQL proven in scratch DB: racing insert is a no-op, `aborted` re-claimable).
2. ✅ RunSpec extraction + TaskGroup concurrency with caps (2026-07-07;
   verified live: 3×5s echo tasks at cap 2 → 10.6s wall, honest per-outcome
   ledger timestamps; default `maxConcurrent` 1 = v1 behavior). Note: outcome
   recording happens inline in the group-collection loop (serial on the
   calling task), not a separate pass — per-run `finished_at` stays accurate.
3. ✅ Result trailer + ledger `summary` column + `update --append-notes`
   (2026-07-07; verified live, trailer lands in task notes).
4. ✅ Worktree GC in the reap phase (2026-07-07; verified live in a scratch
   repo: merged succeeded → worktree+branch removed; unmerged succeeded →
   surfaced as pending; failed older than `keepFailedWorktreeDays` (default
   7) → worktree removed, empty branch deleted, non-empty branch kept.
   `--no-gc` opts out; git chatter routed to /dev/null).
5. ✅ Notify hook (2026-07-07; `notifyOn: "failure"` (default) | "all" |
   "none" in agents.json; JXA displayNotification via OSA.runJXA, args passed
   as argv, best-effort; fired live once with "all" during verification).

All five steps landed 2026-07-07. Remaining follow-ups: README + MCP tool
descriptions still describe v1 (sequential, no summary column, no
--append-notes); update both.
