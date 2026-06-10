# Ideas / Roadmap

Extensions for broader Apple-ecosystem integration. Architecture rule for all of
them: the Swift CLI stays dumb, fast, and JSON-speaking; agents (via MCP) make
every judgment call.

## 7. Agent dispatcher — closing the loop (CORE SLICE ✅ BUILT 2026-06-09)

**Implemented**: SQLite audit log + dispatch ledger
(`~/.config/apple-tasks/apple-tasks.db`, WAL, raw sqlite3 — `Audit.swift`);
audit hooks in every mutating command with caller attribution via
`APPLE_TASKS_CALLER` env (MCP sets "mcp"; dispatcher sets "agent:<tag>" on
spawned agents; fallback = parent process name); `apple-tasks log` /
`dispatches` subcommands + MCP `audit_log` tool (21 tools total);
`apple-tasks dispatch [--dry-run] [--agent X] [--list Y]` reading
`~/.config/apple-tasks/agents.json` (agents/command templates with {prompt},
workdirs tag→folder, requireAutoTag default true). Dedupe = ledger row AND
[dispatched]/[failed] tag check. Verified end-to-end with an echo agent:
dry-run → dispatch (cwd from workdir tag, prompt rendered with task id/title/
notes + self-complete instructions) → ledger succeeded → re-dispatch deduped.
Live config has claude wired (`claude -p {prompt} --permission-mode
acceptEdits`) — UNTESTED with a real claude run yet; start with --dry-run.

**Remaining for next session**: `--watch` mode (EKEventStoreChanged or poll
loop) + launchd plist; per-agent concurrency (v1 is fully sequential);
model-tag → flag mapping; notify on completion/failure. (Timeout handling and
run-log capture landed with hardening — see #10.)

### Original design sketch (2026-06-09 afternoon)

Today the flow is: capture (Siri/Reminders anywhere) → triage → agents *pull*
work when a human starts them. The missing piece is **push**: a dispatcher that
watches the task queue and launches the right agent automatically, so a
reminder spoken into a watch becomes running agent work with no human at the
keyboard.

Examples that should Just Work:
- Task `[claude][repo2] Add MFA to sign in page` → dispatcher spawns
  `claude -p "read and do the new tasks in AgentTasks assigned to claude"`
  with cwd already set to repo2's folder.
- Task `[gemini][calendar] Add notes to today's meetings` → spawns gemini CLI
  with the Google MCP loaded so it can pull relevant emails for today's
  meetings.

### Design sketch

- **Routing config** `~/.config/apple-tasks/agents.json`:
  - `agents`: tag → command template, e.g.
    `claude: "claude -p {prompt} --permission-mode acceptEdits"`,
    `gemini: "gemini -p {prompt}"` (each agent's MCP config is its own).
  - `workdirs`: repo tag → folder, e.g. `repo2: ~/Code/repo2`. First matching
    workdir tag on the task sets cwd.
  - `models`: optional tag → model flag mapping (`[opus]` → `--model opus`).
- **Trigger options** (pick one to start):
  1. Poll loop in the dispatcher (`apple-tasks list -t <agent> --status open`
     every N min) — dumbest, works headless via launchd.
  2. `EKEventStore` change notifications (`.EKEventStoreChanged`) — a tiny
     resident process (or the AgentTasks app itself) reacts within seconds of
     any Reminders change, then diffs for new agent-tagged tasks. Best UX.
  3. AgentTasks app menu-bar mode: shows queue + "dispatch now" button +
     run history; manual but visible.
- **Dispatch protocol / dedupe**: dispatcher adds a `[dispatched]` tag (native
  mirror makes it visible) before spawning; agent removes it and
  `task_complete`s on success, or replaces with `[failed]` + notes on error.
  Never dispatch a task already tagged `[dispatched]`/`[failed]`.
- **Safety rails**: only dispatch tasks also tagged `[auto]` at first
  (human-in-the-loop by default); per-agent concurrency limit of 1; timeout +
  `[failed]` on overrun; log everything to ~/.config/apple-tasks/runs/.
- **Report-back**: agent (or dispatcher on exit) fires `notify` + the morning
  digest can read completed-since-yesterday.
- **Siri tie-in**: with the schema intents this means "Hey Siri, remind me to
  add MFA to repo2, tag claude and auto" → dispatcher picks it up → Claude is
  coding it before you've put the phone down. The full voice-to-PR loop.

### Audit log + dispatch ledger (SQLite)

One DB at `~/.config/apple-tasks/apple-tasks.db` (WAL mode for concurrent
writers; raw SQLite3 C API, no dependency). Reminders remains the source of
truth for task STATE; SQLite is the machine-side memory.

- **Write it in the CLI, not the MCP.** Every caller (MCP, App Intents app,
  dispatcher, bare terminal) already funnels through the Swift binary — one
  implementation covers all paths, including Siri-created tasks. Callers
  identify themselves via `APPLE_TASKS_CALLER` env (mcp/app/dispatcher);
  fallback = parent-process lookup (doctor already does this). The MCP server
  just sets the env var on every shell-out.
- **`audit` table** (append-only): ts, caller, command, task_id, external_id,
  list, args summary (REDACT note bodies), result ok/error, error_text,
  duration_ms. Log all mutations; log scans minimally (they advance
  watermarks); skip pure reads or make it configurable.
- **`dispatches` table** (mutable ledger): task_id, agent, command, cwd,
  prompt, started_at, finished_at, status running/succeeded/failed/timeout,
  exit_code, run_log_path. This is the AUTHORITATIVE dedupe — the
  `[dispatched]` tag stays as the human-visible signal, but the dispatcher
  checks the DB, so manual tag edits can't cause double-runs.
- **Surfacing**: `apple-tasks log [--since --task --caller]` and
  `apple-tasks dispatches [--status running]` subcommands + MCP `audit_log`
  tool. Agents asking "did I already do this?" = idempotency for free. Feeds
  the morning digest. `doctor` reports DB path/size/last-write.

### Open questions for next session

- Headless `claude -p` permission posture: which permission mode is safe for
  unattended runs? Worktree isolation per task?
- Does the dispatcher live in the AgentTasks app (visible, GUI, TCC already
  granted) or a launchd agent (robust, headless)? Leaning: start as
  `apple-tasks dispatch --watch` subcommand, promote to launchd once stable.
- Per-agent prompt templates: generic "read your queue" vs injecting the
  specific task title/notes into the prompt (probably the latter — less agent
  spelunking, and the task id can be passed for direct task_complete).

## 1. Calendar support — ✅ DONE

Events live in the same EventKit framework as reminders. CLI gained
`events list/add/update/delete` + `calendars`; MCP gained `event_*` /
`calendar_list` tools. Same `[tag]` title-prefix convention as tasks, so agents
can tag time blocks (`[claude][repo2] Deep work: MFA`).

Killer combo: agent reads free calendar slots and time-blocks tagged tasks, or
converts a due-dated task into a real event.

Notes:
- Separate TCC permission from Reminders (Calendars full access, macOS 14+).
- Event queries require a date range (`predicateForEvents`); CLI defaults to
  today → +7 days.
- Recurrence not implemented yet.

## 2. Siri inbox triage pattern — ✅ DONE (convention, see README)

No new API. Reminders already sync from Siri/watch/iPhone/CarPlay. Designate an
inbox list, capture by voice anywhere, and run a triage agent on a loop
(`/loop`) that picks up untagged tasks, classifies them, tags them, and routes
them to the right plan list via `task_update`.

- Siri's default capture ("Hey Siri, remind me to X") lands in the default
  "Reminders" list — zero-friction but mixes with personal items; triage agent
  must only touch untagged items and leave personal ones alone (or tag them
  `[personal]`).
- A dedicated "Inbox" list is cleaner but requires saying "...to my Inbox list".
- Sample triage prompt lives in README.

## 3. Notes scanning → reminders/events — ✅ DONE (user's idea)

Implemented as `apple-tasks notes scan` (+ MCP `notes_scan`). JXA via osascript,
bulk property fetches, HTML stripped to plain text, bodies truncated
(`--max-chars`, default 4000). Watermark state at
`~/.config/apple-tasks/state.json` auto-advances on stateful scans; `--since`
runs stateless. `--folder` scopes the scan. Read-only by design.

Original design notes:

Scan new/modified notes for action items; agent extracts and creates tagged
reminders or calendar events.

API reality:
- Notes has NO public framework. Only AppleScript/JXA: note name, body (HTML),
  folder, creation/modification dates, id.
- No change notifications → poll: `notes scan --since <timestamp>` subcommand
  (shell out to `osascript` from Swift, or a separate script), keep a state file
  of processed note ids + modification dates.
- Password-protected notes are invisible to scripting.
- Body comes back as messy HTML → strip to plain text before handing to agent.
- READ-ONLY: writing back into note bodies via AppleScript mangles formatting.
  For provenance, put the source note's title into the created reminder's notes
  field instead. (No reliable public URL scheme to deep-link a specific note.)
- Division of labor: CLI surfaces raw candidate text; the LLM decides what's an
  event ("meet Sarah Tuesday 3pm") vs a task ("renew cert") vs noise.

## 4. Shortcuts bridge — ✅ DONE

Implemented as MCP tools `shortcut_list` and `shortcut_run(name, input?)` (temp
file in/out via `--input-path`/`--output-path`). No Swift changes needed.

Original design notes:

macOS ships a `shortcuts run <name>` CLI (also `shortcuts list`). One MCP tool
`shortcut_run(name, input?)` gives agents everything Shortcuts can touch:
HomeKit, Focus modes, rich notifications, playlists, etc. It's the escape hatch
for every Apple surface without an API — define the capability visually in
Shortcuts.app, agent invokes it. Trivial to implement (~30 lines in the MCP
server, no Swift changes).

## 5. Messages / notifications report-back — ✅ DONE (notification banner only)

Implemented as MCP tool `notify(title, message, sound?)` via osascript
`display notification`. Messages self-DM deliberately NOT implemented (sends
from the user's own Apple ID); a push service (ntfy/Pushover) is the upgrade
path if off-Mac pings are wanted.

Original design notes:

Close the loop: agent finishes an overnight task → ping the user.

- Caveat (confirmed): scripting Messages.app sends from YOUR Apple ID — it's a
  self-DM. Still pops on watch/phone like any text, but reads as "you".
- Cheap local option: `osascript -e 'display notification "..." with title "..."'`.
- Third-party-feeling option: push service (ntfy.sh / Pushover) — looks like a
  real sender, works off-Mac.
- Could also just be a `[done]` tag + completed-status query in the morning.

## 6. Mail triage — ✅ DONE (read-only scan/show)

Implemented as `apple-tasks mail scan` (headers since timestamp, newest first,
`--limit`) and `apple-tasks mail show <id>` (plain-text body, truncated) + MCP
`mail_scan`/`mail_show`. JXA against Mail.app's unified inbox. Read-only — no
draft creation yet. Note: returns [] if Mail.app isn't syncing the account
(confirmed: Google account configured but 0 messages synced on this machine —
open Mail.app to populate).

## WWDC 2026 (iOS 27 / macOS 27 "Golden Gate") — researched 2026-06-09

New Siri is a context-aware assistant (custom Gemini-powered); betas out now,
ships ~Sept 2026. Relevant to this project:

- **App Intents is now THE integration path** (SiriKit formally deprecated).
  New: App Intents Schemas (system-defined structures Siri understands
  natively), View Annotations API, App Intents Testing framework. Entity
  schemas feed Spotlight's semantic index.
  - Opportunity: a thin macOS app target exposing our plans/tasks as App
    Intents entities → "Hey Siri, what's open for the claude agent in
    repo2-plan?" works natively, and tasks surface in Spotlight. Biggest
    new-OS win available to us.
- **Siri Extensions framework**: third-party AI apps/agents can plug into
  Siri/the Siri app directly. Worth evaluating once docs mature — could make
  the agent queue itself a Siri-callable surface.
- **Foundation Models framework, provider-agnostic**: Language Model protocol
  supports Apple models, Claude, Gemini, or custom. Opportunity: run the
  inbox/notes triage loop on-device for free instead of burning API tokens —
  the classification task is small enough for a local model.
- **Reminders/Calendar gain user-facing natural-language creation** (no new
  public API for it found). Still NO public EventKit API for native tags or
  subtasks as of iOS 27 — our [tag] convention remains necessary.
- **RemCTL** (github.com/viticci/remctl, open source, on MacStories): reads
  Reminders' SQLite directly + ObjC-bridges the private ReminderKit framework
  to read/WRITE native tags, subtasks, sections, smart lists. Proves real tags
  are scriptable — at the cost of private-API fragility (breaks on OS updates,
  needs Full Disk Access). Option: keep [tag] as the stable backbone, add an
  optional remctl-style backend for native tags later.

### iMessage bot TOS — CONFIRMED PROHIBITED (2026-06-09)

Automated messaging on personal iMessage accounts violates Apple's ToS —
explicitly including AppleScript automation of Messages.app (also BlueBubbles,
pypush; protocol reverse-engineering may additionally implicate the CFAA).
The only sanctioned route is **Apple Messages for Business** (enterprise
program, not a personal-agent fit). Decision stands: `notify` banner + future
ntfy/Pushover; never script Messages.app for bot traffic.

## Spikes / next actions (this machine runs the macOS 27 beta — testable now)

1. **remctl spike — ✅ DONE 2026-06-09**, full findings in
   `docs/remctl-spike.md`. Headline: native Reminders tags are writable via a
   ~6-line private-ReminderKit call keyed by the CloudKit identifier — which
   equals the `externalId` our CLI already outputs. No SQLite, no Full Disk
   Access needed for writes. **Implemented 2026-06-09**: `apple-tasks-private`
   helper (built by `make`), default-on additive mirror in `add`/`update` with
   `--no-native-tags` opt-out; `[tag]` prefix stays source of truth; verified
   `nativeTags: true` on macOS 27.0 beta. Still worth copying from remctl:
   `doctor` command (TCC is per-host-process), verify-after-write.
2. **App Intents wrapper spike — ✅ BUILT 2026-06-09** (`spikes/AgentTasksApp`,
   built with Xcode 26.5 SDK — the new iOS 27 schemas/Testing framework need
   the Xcode 27 beta, still TODO). No Xcode project: `build.sh` compiles with
   swiftc + `-emit-const-values-path` + a const-gather protocols file derived
   from the toolchain's `SwiftConstantValues/AppIntents.json` (the frontend
   wants a flat JSON array), then runs `appintentsmetadataprocessor` by hand
   and ad-hoc signs. Two intents shelling out to the CLI: "Check Agent Tasks"
   (tag/list filters) and "Add Agent Task", plus App Shortcuts phrases.
   Verify in Shortcuts app → search AgentTasks; first run TCC-prompts the app
   for Reminders.
   **Xcode 27 beta upgrade — ✅ DONE 2026-06-09**: adopted the new
   **Reminders domain schema** (`@AppIntent(schema: .reminders.createReminder)`,
   `@AppEntity(schema: .reminders.reminder/.list/.section/.locationTrigger)`,
   `@AppEnum(schema: .reminders.listType/.locationTriggerEvent)`). Schema
   shape is compiler-enforced; notably **`tags: Set<String>` is first-class**
   in Apple's schema — the [tag] convention maps directly. Full entity graph in
   `spikes/AgentTasksApp/Sources/SchemaIntents.swift`; metadata confirms
   `assistantDefinedSchemas: [{domain: reminders, name: CreateReminderIntent}]`.
   Build uses DEVELOPER_DIR=Xcode-beta automatically. Other schema intents
   available to adopt later: updateReminder, deleteReminders, createList,
   updateList, create/updateSection, updateGroup. Also new in SDK:
   `IndexedEntityQuery` (Spotlight semantic reindex hooks) and
   `_ModelDelegationIntent` (worth investigating). Remaining: real-device Siri
   conversational test ("remind me to X in AgentTasks"), TaskEntity →
   IndexedEntity for Spotlight.
3. **Siri Extensions framework spike** (beta-testable): can an
   agent/CLI-backed app register as a Siri extension? Docs were thin at
   announcement; re-check as beta docs mature.
4. **Foundation Models triage spike** (beta-testable): port the inbox/notes
   triage prompt to the provider-agnostic Foundation Models framework
   (Language Model protocol) — on-device classification, zero API cost.
   Could become `apple-tasks triage` running fully local.

## Round 3 additions (2026-06-09 evening) — ✅ DONE

- **All four Reminders schema intents adopted** in AgentTasksApp:
  createReminder, updateReminder (entity param is named `target`),
  deleteReminders (`entities: [TaskEntity]` + `typealias Entity`), createList
  (`name` must be OPTIONAL, `type: ListType` must be required — schema quirk).
  All verified registered in extract.actionsdata. Discovery workflow that got
  there: give the intent an empty `init() {}` so swiftc passes, then read the
  metadataprocessor's "Missing required parameter" errors — it validates, the
  macro only wraps.
- **Spotlight semantic indexing**: TaskEntity conforms to IndexedEntity
  (tags → keywords, list → containerTitle); app donates open tasks via
  `CSSearchableIndex.indexAppEntities` on launch.
- **`apple-tasks doctor`** (+ MCP `doctor` tool, 19 total): per-host TCC
  status, host process name, private-helper `--check` probe (regression canary
  for the private ReminderKit API on each beta), notes watermark.
- **`_ModelDelegationIntent` investigated**: underscored SPI —
  `prompt`/`conversationIdentifier`/`supportedFeatures: .systemAssistant` —
  the Siri-delegation hook behind "Siri Extensions" press coverage. Almost
  certainly entitlement-gated; watch for public API in later betas, don't
  build on it.

## 8. Morning digest → Apple Note — TODO

Scheduled agent (cron/launchd, or `/loop` at 7am) reads: audit log since
yesterday (what agents did), dispatch ledger outcomes, open tasks due today,
today's calendar. Writes a digest as a NEW Apple Note (AppleScript `make new
note` is safe — our read-only rule was about editing existing bodies) + fires
`notify`. CLI gains `notes create --folder X --title Y` (body as HTML).
Result: open Notes on your phone over coffee, see what your agents did
overnight and what's on deck.

## 9. Siri voice status — "what did my agents do today?" — TODO

App Intent in AgentTasks backed by `apple-tasks log`/`dispatches`: summarizes
recent audit rows as a spoken dialog. Pairs with the schema intents: voice in
(create/update tasks) AND voice out (status). Trivial now that the audit log
exists — the intent is ~30 lines shelling to `log --since`.

## 10. Dispatcher hardening — ✅ DONE 2026-06-09 (all four verified end-to-end)

- **Reaper**: every dispatch pass first marks ledger rows stuck in 'running'
  longer than `--reap-hours` (default 4) as 'timeout' and swaps the task's
  [dispatched] tag for [failed]; `dispatch --reap-only` runs just this step.
- **Retry policy**: `maxRetries`/`retryBackoffMinutes` in agents.json (default
  off). [failed] tasks re-dispatch once backoff (linear in attempt count) has
  elapsed; audit rows are `dispatch-retry`. Budget spent → stays [failed].
  Verified: attempt 2 + 3 ran, attempt 4 refused; 30-min backoff gated an
  immediate retry.
- **Worktree isolation**: per-agent `"worktree": true` → `git worktree add -b
  agent/<tag>-<ledgerId>` under ~/.config/apple-tasks/worktrees/<ledgerId>,
  agent cwd = worktree, prompt gains a commit-to-current-branch instruction,
  ledger stores the path. Creation failure aborts the dispatch (never runs
  unisolated). Makes acceptEdits unattended-safe.
- **Run logs**: agent stdout/stderr → ~/.config/apple-tasks/runs/<ledgerId>.log
  (with a header: ts, task, command); ledger column `run_log_path`.
- **Bonus — per-run timeout**: per-agent `"timeoutMinutes"` → SIGTERM (SIGKILL
  after 5s grace), ledger status 'timeout' (verified: exit 15 at 61s), task
  tagged [failed] so retry policy applies. Closes the "v1 waits indefinitely"
  gap from #7.
- Schema migration: `run_log_path`/`worktree` columns added via guarded ALTER
  TABLE; old rows read back fine.
- Live agents.json now: claude with worktree+60-min timeout, maxRetries 2,
  backoff 30. Real claude dispatch still untested — start with --dry-run.
- Worktree cleanup is manual for now (`git worktree remove` + branch delete
  after merging); a `dispatch --gc` could prune worktrees of merged branches.

## 11. iPhone/watch capture shortcut (no app needed) — TODO

An iOS Shortcut "Agent Task": asks for text + agent (menu: claude/gemini) +
repo (menu from your workdirs), composes `[agent][repo][auto] title`, adds it
to the right Reminders list natively on the phone. iCloud syncs it; the Mac
dispatcher picks it up. Full voice/Action-button/watch capture → running agent
with ZERO custom iOS code. Document the recipe in README; optionally generate
the shortcut programmatically.

## 12. Mail rules → push-based email capture — TODO

Mail.app rules can run an AppleScript on matching incoming messages. Rule
script creates a tagged reminder ([mail][triage]) with subject + sender in
notes. Push beats our polling `mail_scan` for latency, and the triage agent
already knows what to do with inbox items. Caveat: Mail must be running.

## 13. Multi-Mac claim protocol — KNOWN LIMITATION / TODO

The dispatch ledger is per-machine but tasks sync via iCloud: two Macs running
dispatchers would double-run a task ([dispatched] tag helps but races over
sync lag). Fix: claim tag includes hostname ([dispatched:mbp]) and dispatchers
only reap/retry their own claims; or designate one dispatch machine via
config. Note in README if a second Mac ever runs the dispatcher.

## 14. CoreLocation "whereami" — ✅ BUILT 2026-06-10

`apple-tasks whereami` (+ MCP `whereami` tool): one-shot fix with reverse
geocode, `--timeout` / `--no-geocode`; `doctor` reports Location Services
status. Implementation note: the classic CLLocationManager delegate API
NEVER fires in a bare CLI (no runloop) — use the async
`CLLocationUpdate.liveUpdates()` API (macOS 14+), which also triggers the
TCC prompt itself. Info.plist gained NSLocation[WhenInUse]UsageDescription.
TCC grant is per-host-process; first-run prompt must happen from a real
terminal (sandboxed/headless shells can't display it). Uses: location-aware
triage, am-I-home dispatcher gating, geotagging the morning digest.

## 15. FindMy.py sidecar — real Find My data — TODO (researched 2026-06-09)

Find My itself is locked down (verified on macOS 27 beta): no AppleScript
dictionary; cache TCC-protected AND encrypted since macOS 14.4; the four
FindMy intents (LocateDevice/Locate/PlaySound/ToggleLocationSharing) are
SiriKit-only in private SiriFindMy.framework — not Shortcuts actions, so the
shortcut_run bridge can't reach them. Voice already works ("Hey Siri, where's
my iPhone") — no MCP needed for that.

**✅ BUILT 2026-06-10** as `sidecar/findmy-sidecar.py` on
[FindMy.py](https://github.com/malmeloo/FindMy.py) (v0.9.x): subcommands
`login` (interactive-only — refuses non-TTY; Apple ID + 2FA via
LocalAnisetteProvider; session → `~/.config/apple-tasks/findmy/account.json`
chmod 600, re-saved after fetches since tokens rotate), `status`, `devices`,
`locate <name>`. Accessories = AirTag pairing `.plist` / FindMy.py `.json`
exports dropped in `~/.config/apple-tasks/findmy/accessories/`. MCP gained
`findmy_devices` / `findmy_locate`; python resolved from the dedicated venv
(`~/.config/apple-tasks/findmy/venv`, auto-detected; override
`APPLE_TASKS_FINDMY_PYTHON`). `doctor` reports sidecar config state.
Errors come back as JSON `{error, hint}` so agents can self-serve setup
guidance. **Untested with a real account/accessory yet** — login + plist
export are manual first-run steps. NOT doing: FindMySyncPlus-style cache
decryption (debugger key extraction, fragile, unproven on macOS 27).

## 16. Pre-publish hardening & security review — TODO (process step)

Before publishing the repo, run a dedicated review session:

- `/security-review` over the full tree. Known hot spots to scrutinize:
  prompt template rendering (task title/notes flow into agent prompts —
  prompt-injection surface for dispatched agents), dispatcher command
  construction from agents.json, audit-log redaction (notes bodies should
  stay out), findmy sidecar session file handling, MCP tool input → CLI
  argv paths (execFile is argv-safe, keep it that way — never shell
  interpolation).
- Hardening pass: pin/document the FindMy.py version; decide what example
  config ships vs. what's gitignored (agents.json contains local paths;
  apple-tasks.db and runs/ logs must never be committed).
- Re-run `/code-review high` on the dispatcher + sidecar as a unit.

## Status: all six ideas implemented (v0.1)

18 MCP tools total (19 with doctor). Remaining future work, roughly in value order:
- Recurrence support for tasks and events.
- Due-date filters on `task_list` (`--due-before`, overdue) for "what's on deck
  today" queries.
- Mail draft creation (AppleScript can make drafts; never auto-send).
- Push-service notify (ntfy/Pushover) for off-Mac report-back.
- Watermark state for mail_scan (currently stateless, default 24h lookback).
