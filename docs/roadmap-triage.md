# Roadmap triage — 2026-07-07

Ruthless pass over IDEAS.md's open items (post dispatcher-v2). Numbers refer
to IDEAS.md sections. Grounding: dispatcher v2 landed today (atomic claim,
concurrency, result trailers, worktree GC, notify), the FoundationModels
executor seam is runtime-blocked (§33), and Fable-tier design time is best
spent on specs cheaper models can execute.

## The narrative these serve

Two loops this project is building:
- **Voice-to-PR**: capture anywhere → triage → dispatch → work happens →
  report-back reaches you anywhere.
- **Agent ops**: a supervisor agent that can watch, diagnose, and re-drive
  the dispatcher without a human terminal.

Every kept item below advances one of the two.

## Sequence (build in this order)

| # | Item | Why now | Size |
|---|------|---------|------|
| 1 | #18 MCP dispatcher control tools | closes the agent-ops loop; near-zero Swift | S |
| 2 | #24 ntfy push notify | completes report-back; notifyOn hook exists | S |
| 3 | #19 task URL linkback | provenance; tiny | S |
| 4 | #8 morning digest → Apple Note | reads v2 ledger summaries; needs `notes create` | M |
| 5 | #27 on-device triage (`apple-tasks triage`) | zero-cost; likely NOT blocked by §33 (see spec) | M |
| 6 | #32 `make betacheck` | 20 lines, pays for itself every beta | XS |
| 7 | #22 context-gated dispatch | whereami + pmset reads; rails for heavier autonomy | M |
| 8 | #17 Contacts read-only | new TCC surface; triage quality | M |
| 9 | #9 Siri voice status intent | trivial after #18; app work | S |
| 10 | #11 capture shortcut recipe | docs only | XS |
| 11 | #23 drop-folder capture (+#20 OCR, +#21 audio as satellites) | one inbox-folder concept, three scanners | L |
| 12 | #26 sections/subtasks (private helper round 2) | visual plan phases; canary-gated | M |
| 13 | #29/#31 AgentTasksApp: calendar/notes schema domains + continuous Spotlight donations | app modernization batch | L |
| 14 | #13 multi-Mac claim (hostname in claim + config) | only if a 2nd Mac ever dispatches | S |
| 15 | #16 security review | REQUIRED gate before the repo goes public | M |

**Blocked/watching**: #28 ClaudeForFoundationModels + our spike (§33 — retry
on next Xcode beta drop); #30 Siri Extensions (Apple backend off); FindMy
live test (needs your Apple ID login + AirTag plist export — manual).

**Killed/parked**: #25 Safari Reading List (only FDA-requiring idea — user
already flagged ships-last; park until someone actually wants it); #12 Mail
rules push (fragile — Mail must run, rule scripts are per-machine state;
`mail_scan` + a watermark covers 90% at zero fragility; revisit only if
scan latency actually hurts); #7 `--watch` mode (launchd interval + the
existing one-shot dispatch is simpler than a resident watcher; revisit if
sub-minute latency ever matters).

---

## Build-ready specs (top 5)

### 1. MCP dispatcher control tools (#18)

Goal: a supervisor agent can run the whole ops loop over MCP.
Files: `mcp/src/server.ts` only.
- `task_show(id)` → `show <id>`; `task_uncomplete(id)` → `uncomplete <id>`.
- `dispatch_run({dry_run=true, agent?, list?, reap_only?})` → `dispatch`
  argv. **Default dry_run TRUE**; the description must say a real run
  launches agents and consumes their budgets.
- `dispatch_list({status?, limit=50})` → `dispatches`.
- `run_log({ledger_id, tail=100})` — read
  `~/.config/apple-tasks/runs/<id>.log` directly in Node (no CLI verb
  needed); tail semantics, cap bytes (256 KB) so a runaway log can't flood
  a context window.
Verify: stdio smoke (initialize → tools/list → dispatch_run dry_run) like
today's `append_notes` check; count goes 23 → 28.
Risk: recursive dispatch (agent triggers dispatch which spawns agents).
Mitigation: `dispatch_run` refuses (returns error) when
`APPLE_TASKS_CALLER` starts with `agent:` — dispatched agents may not
re-dispatch; only top-level MCP sessions may.

### 2. ntfy push notify (#24)

Goal: report-back that reaches your phone off-Mac.
Files: `Sources/AppleTasks/Dispatch.swift` (notify helper), new
`~/.config/apple-tasks/notify.json` (`{"ntfy": {"topic": "...", "server":
"https://ntfy.sh"}}`, gitignored), `mcp/src/server.ts` (`notify` tool gains
`push: bool`), README.
- `Self.notify` gains a push leg: POST body=`body`, header `Title: <title>`
  to `<server>/<topic>` via URLSession; fire-and-forget with 10s timeout.
- Dispatcher: push on failure/timeout always (when configured), banner per
  `notifyOn` as today. CLI `apple-tasks notify <title> <body> [--push]` new
  subcommand so shortcuts/scripts can use it too.
Verify: configure a throwaway topic, dispatch a failing echo agent, confirm
the phone ping; unset config → silently banner-only (no error).

### 3. Task URL linkback (#19)

Goal: task ↔ PR/commit provenance visible on every device.
Files: `Commands.swift` (`--url` on add/update, emit in TaskOut),
`Events.swift` (same for events), `mcp/src/server.ts` (url params),
`Dispatch.swift` (default prompt template gains: "If your work produced a
PR/commit/file, set it: `apple-tasks update {id} --url <link>`").
EKCalendarItem.url is public API; null handling: `--clear-url` like
`--clear-due`. Verify: add → show round-trip; URL visible in Reminders.app.

### 4. Morning digest → Apple Note (#8)

Goal: open Notes over coffee, see what agents did + what's on deck.
Files: `Automation.swift` (+`notes create` JXA — `make new note` is safe,
our read-only rule was about EDITING bodies), `Commands.swift` (Notes
subcommand gains `create --folder --title --body-html`), new
`docs/digest-prompt.md` (the agent prompt), README cron/loop recipe.
Digest content (agent-composed, CLI provides the reads — all exist):
`log --since yesterday`, `dispatches --limit 20` (now with summaries),
`list --status open` due today, `events list` today. Schedule: `/loop` or
launchd at 7am running `claude -p` with the digest prompt; the dispatcher
is NOT involved (this is a read+write-note task, no worktree).
Verify: run the digest prompt once by hand; confirm note appears, notify
fires, nothing edits existing notes.

### 5. On-device triage (#27) — `apple-tasks triage`

Goal: the 7am inbox/notes/mail triage runs free, offline, on-device.
Key insight vs §33: the runtime skew hits the CUSTOM-provider seam
(executor channel). Using `SystemLanguageModel.default` through
`LanguageModelSession.respond` + `@Generable` exercises only 26.0-era API —
**expected to run on beta 3 despite §33**. First step is a 20-line probe
binary (session + trivial @Generable round-trip, dyld-run it — per the
§32 drill update, compile-clean is not proof).
Files: new `Sources/AppleTasks/Triage.swift`; probe in `spikes/`.
- `@Generable struct Classification { kind: task|event|noise; tags:
  [String]; due: String?; title: String }`.
- Input: `--from notes|mail|inbox` (reuses existing scan/list code paths),
  emits classification JSON; `--apply` creates the tagged tasks/events
  (default off — dry-run posture like dispatch).
- Escalation ladder later (PCC/Claude, §28) — same session API, blocked
  on §33; ship on-device-only first.
Verify: probe runs → triage --from inbox on synthetic items → --apply
creates correctly tagged tasks; audit rows recorded.

---

Suggested batch boundaries for /make-plan → /do execution: (1+2+3) one
session "dispatcher ops & report-back"; (4) one session; (5) one session
starting with the probe; (6..10) a cleanup session; (11+) each their own.
