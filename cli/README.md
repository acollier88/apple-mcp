# apple-tasks (CLI)

> **Product 1 of 2** in this monorepo — the agent-facing API.
> See [../docs/architecture.md](../docs/architecture.md) for how this relates to
> the [AgentTasks](../apps/AgentTasks) ops/Siri app, and [../mcp/](../mcp/) for
> the MCP wrapper.

Apple Reminders as an agent task queue. This Swift CLI (EventKit) is the backbone;
the MCP server in `../mcp` exposes the same surface to agents. Plans and tasks stay
fully visible in the Reminders app on Mac, iPhone, and watch.

## Conventions

- **A plan = a Reminders list. A task = a reminder in it.**
- **Calendar events use the same `[tag]` convention**, so agents can tag time blocks.
- **Tags are `[tag]` prefixes on the title**: `[Claude][repo2] Add MFA to sign in page`.
  Only *leading* bracket groups count as tags; tags can't contain spaces or brackets.
  The CLI/MCP always parses them out, so consumers see
  `{"title": "Add MFA to sign in page", "tags": ["Claude", "repo2"], ...}`.

This convention exists because EventKit exposes neither native Reminders `#tags`
nor subtask relationships — title prefixes and lists are the portable equivalents.

## Build

```bash
# from repo root:
make            # builds the CLI and the optional native-tags helper
# binaries: cli/.build/release/apple-tasks, cli/.build/release/apple-tasks-private

# or from this directory:
make cli && make helper
swift build -c release   # CLI only; everything works without the helper
```

### Native tag mirroring

When tags are written (`add -t`, `update --add-tag`), the CLI also mirrors them
to **real Reminders tags** via `apple-tasks-private`, a small helper that uses
Apple's private ReminderKit framework (see `docs/remctl-spike.md`). The `[tag]`
title prefix remains the source of truth — the mirror is additive-only and
best-effort:

- Output gains `"nativeTags": true|false` on add/update (omitted if no tags).
- A failed mirror warns on stderr but never fails the command.
- Removal only updates the prefix; ReminderKit exposes no tag-removal API, so
  stale native tags must be removed in the Reminders app.
- `--no-native-tags` skips the mirror; deleting the helper binary disables it
  globally. `APPLE_TASKS_PRIVATE_BIN` overrides the helper path.
- Private API caveat: may break on any macOS update (the helper probes every
  class/selector and fails gracefully). Verified working on macOS 27.0 beta.

First run prompts for Reminders access (macOS 14+ "full access"), attributed to the
terminal/app that launched it. Grant in System Settings > Privacy & Security > Reminders.

The same helper also nests reminders as **native subtasks**: `apple-tasks
update <child> --parent <parent>` (and MCP `task_update` `parent`) makes one
task a subtask of another — so a plan list can show agent work as parent +
steps instead of a flat pile. `"subtask": true|false` appears in the output;
`doctor`'s private-helper `--check` reports `"subtasks": true` when the API is
present. Note: a subtask op changes the reminder's *local* id (the sync-stable
`externalId` is unaffected — prefer it for follow-up calls). Detaching a
subtask is intentionally not exposed: ReminderKit's `removeFromParentReminder`
leaves the reminder un-filed and thus invisible to EventKit (roadmap #26).
Sections aren't mirrored yet (the reminder→section reference is unproven).

## CLI

```bash
apple-tasks lists                                  # show lists (plans)
apple-tasks lists add "repo2-plan"                 # create a list
apple-tasks add --list "Code Tasks" -t claude -t repo2 \
    --due 2026-06-10 --priority high "Add MFA to sign in page"
apple-tasks list --list "Code Tasks" -t claude     # open tasks tagged claude
apple-tasks list --status all                      # everything, everywhere
apple-tasks list --overdue                         # due date has passed
apple-tasks list --due-before 2026-07-12           # due before then (whole day incl.)
apple-tasks update <id> --add-tag backend --remove-tag repo2 --title "New title"
apple-tasks update <child-id> --parent <parent-id>   # native subtask (private helper)
apple-tasks complete <id>
apple-tasks uncomplete <id>
apple-tasks delete <id>
apple-tasks show <id>
```

All output is compact JSON. Errors go to stderr with exit code ≠ 0.
Task ids accept either the local or sync-stable external identifier.

### Calendar events

Calendar access is a separate macOS permission from Reminders (granted the same way).

```bash
apple-tasks calendars                              # list calendars (+ writable flag)
apple-tasks events list                            # today through +7 days
apple-tasks events list --from 2026-06-11 --to 2026-06-12 -t claude
apple-tasks events add --calendar Home -t claude -t repo2 \
    --start "2026-06-11 09:00" --duration 90 "Deep work: MFA implementation"
apple-tasks events add --start 2026-06-12 "Release day"   # date-only start = all-day
apple-tasks events update <id> --start "2026-06-11 13:00" --end "2026-06-11 14:30"
apple-tasks events delete <id>
```

### Notes & Mail (read-only, via Apple Events)

Notes and Mail have no public framework; these shell out to JXA. First use may
prompt for Automation permission ("Terminal wants to control Notes/Mail").

```bash
apple-tasks notes scan                       # notes modified since last scan
                                             # (watermark in ~/.config/apple-tasks/state.json;
                                             #  first run looks back 24h)
apple-tasks notes scan --since 2026-06-01 --folder Work --max-chars 500   # stateless
apple-tasks mail scan --since 2026-06-02 --limit 20    # inbox headers, newest first
apple-tasks mail show <id> --max-chars 2000            # one message with body
```

Bodies come back as plain text (HTML stripped). Password-protected notes are
invisible to scripting. `mail scan` returns `[]` unless Mail.app is actually
syncing the account.

AgentTasks also adopts the Notes App Intents domain (macOS 27,
`NotesSchemaIntents.swift`): *"Hey Siri, create a note in AgentTasks"*
shells to `notes create` under the hood. Calendar/mail domain adoption was
attempted and descoped — see [roadmap #29](../docs/roadmap.md) for the reasons why.

### Contacts (read-only, always)

CNContactStore is public API — no JXA needed, but it's a separate Contacts
TCC prompt per host process (`doctor` reports it).

```bash
apple-tasks contacts search sarah            # by name → id, emails, phones, birthday, addresses
apple-tasks contacts search sarah@corp.com   # '@' in the query switches to email match
apple-tasks contacts show <id>
```

Agents never edit the address book — there is deliberately no write path.

## MCP server

See [`../mcp/README.md`](../mcp/README.md) for install and the full tool list.
Summary of tools (35):

- Tasks: `task_list`, `task_show`, `task_create`, `task_update`,
  `task_complete`, `task_uncomplete`, `task_delete`
- Plans: `plan_list`, `plan_create`
- Events: `event_list`, `event_create`, `event_update`, `event_delete`, `calendar_list`
- Notes/Mail: `notes_scan`, `mail_scan`, `mail_show` (read-only),
  `note_create` (NEW notes only — existing notes are never edited)
- Capture channels: `screenshots_scan` (on-device Vision OCR of an image
  folder), `files_scan` (text/markdown dropped in an iCloud inbox folder,
  optional archive) — both watermarked; feed the text to triage
- Contacts (read-only, always): `contact_search` (by name, or by email when
  the query contains `@`), `contact_show` — resolve WHICH Sarah a task means,
  rank known senders in mail triage; separate Contacts TCC prompt, `doctor`
  reports the grant
- Bridges: `shortcut_list`, `shortcut_run` (escape hatch to HomeKit/Focus/anything
  Shortcuts can do), `notify` (banner; `push: true` also sends via ntfy so it
  reaches your phone — config `~/.config/apple-tasks/notify.json`:
  `{"ntfy": {"topic": "your-topic"}}`, optional `"server"`; never commit it)
- Dispatcher ops: `dispatch_run` (dry-run by default; refuses recursive
  dispatch from agent-spawned sessions), `dispatch_list`, `run_log` — a
  supervisor agent can reap, retry, and read failure logs over MCP
- Location: `whereami` (this Mac), `findmy_devices` / `findmy_locate` (AirTags
  via the FindMy.py sidecar — see below)
- Triage: `triage_inbox` (one-shot classify + route untagged inbox items; dry-run by default)
- Digest: `digest` (agent activity + dispatch outcomes + due today + today's
  calendar as one JSON blob; `note: true` writes it as an Apple Note,
  `push: true` sends a one-line ntfy summary)
- Introspection: `audit_log`, `doctor`

The CLI mirrors the push path as `apple-tasks notify <title> <message>
[--push]`; the dispatcher pushes failures/timeouts automatically when
notify.json is configured (banners follow `notifyOn`).

The server shells out to the Swift binary at `cli/.build/release/apple-tasks`;
override with the `APPLE_TASKS_BIN` env var.

### Location: whereami & Find My sidecar

`apple-tasks whereami` (+ MCP `whereami`) returns a one-shot CoreLocation fix
for this Mac with a reverse-geocoded place name. First use triggers a Location
Services TCC prompt; like Reminders, the grant is **per host process** (grant
Terminal ≠ grant your MCP host) — `doctor` reports the status. Agents can use
it for "am I home?" checks, location-aware triage, and geotagging digests.

Real Find My data (AirTags etc.) has no public API, so it ships as an
**optional sidecar** built on [FindMy.py](https://github.com/malmeloo/FindMy.py).
Setup (one-time):

```bash
python3 -m venv ~/.config/apple-tasks/findmy/venv
~/.config/apple-tasks/findmy/venv/bin/pip install FindMy
~/.config/apple-tasks/findmy/venv/bin/python3 ../tools/findmy/findmy-sidecar.py login   # Apple ID + 2FA
# then drop AirTag pairing .plist / accessory .json files into
# ~/.config/apple-tasks/findmy/accessories/ (see FindMy.py docs for export)
```

The MCP server auto-detects that venv (override with
`APPLE_TASKS_FINDMY_PYTHON`). Session tokens are stored at
`~/.config/apple-tasks/findmy/account.json` (mode 600) — treat that file like
a password. **Caveats:** FindMy.py reverse-engineers Apple's Find My network;
it is read-only against your own account, but it is not a sanctioned API and
may break with Apple changes. Use a dedicated Apple ID if you're uncomfortable
attaching your main one. The `login` step is interactive by design and is
refused when invoked non-interactively (e.g. by an agent).

### Notes-to-tasks triage loop

> /loop 1h Call notes_scan() (the watermark advances automatically). For each
> returned note, extract action items: things with a date/time become calendar
> events (event_create), actionable work becomes tagged tasks (task_create,
> list "Code Tasks" or the right plan). Put the source note's name in the
> created item's notes field. Ignore journal-style content; when unsure, skip —
> never create duplicates of items you created in a previous iteration.

## Agent routing pattern

Give an agent a standing instruction like:

> Query `task_list(tags: ["claude"])`, pick up open tasks, do the work,
> then `task_complete(id)`.

Tag tasks with the agent (`[claude]`, `[codex]`), the repo (`[repo2]`), or the
model to run with (`[opus]`) — any combination, filtered with AND semantics.

## Dispatcher & audit log

Every mutation is recorded to `~/.config/apple-tasks/apple-tasks.db` with
timestamp and caller (`mcp`, `agent:<tag>`, or the parent process). Inspect
with `apple-tasks log` / `apple-tasks dispatches`, or the `audit_log` MCP tool.

`apple-tasks dispatch` finds open tasks tagged `[auto]`, marks them
`[dispatched]`, and launches an agent with a prompt containing the task
details and self-complete instructions. A leading tag that matches an
`agents.json` lane (`[cursor]`, `[hermes]`, …) **pins** that provider.
`[auto]` with no lane tag walks `modelPrefs.auto` and takes the first
**available** worker (command/llm present, under `maxConcurrent`, gates
pass; `worktree: true` lanes need a workdir tag). Classifier/ops lanes
(`triage`, `local`, `doctor`) are never in the auto pool. If nothing is
available the task stays queued — it is not `[failed]`. Config at
`~/.config/apple-tasks/agents.json`:

```json
{
  "agents": {
    "claude": {
      "command": ["claude", "-p", "{prompt}", "--permission-mode", "acceptEdits"],
      "worktree": true,
      "timeoutMinutes": 60,
      "maxConcurrent": 1,
      "conditions": { "location": "home", "power": "ac", "maxLoad": 8 }
    }
  },
  "places": { "home": { "lat": 30.46, "lon": -97.63, "radiusM": 200 } },
  "triage": { "agent": "triage", "inbox": "Reminders" },
  "workdirs": { "repo2": "~/Code/repo2" },
  "requireAutoTag": true,
  "maxRetries": 2,
  "retryBackoffMinutes": 30,
  "maxConcurrent": 2,
  "keepFailedWorktreeDays": 7,
  "notifyOn": "failure",
  "modelPrefs": { "auto": ["hermes", "cursor", "claude", "antigravity"] },
  "autoBudget": "skipRed"
}
```

The first task tag matching a `workdirs` key sets the agent's working
directory. Dedupe is enforced by both the dispatch ledger and the
`[dispatched]`/`[failed]` tags. Always test routing with
`apple-tasks dispatch --dry-run` first.

Starter config (includes **cursor**, **hermes**, **doctor**, claude, antigravity, triage):
[`examples/agents.json`](../examples/agents.json).

### Supported agent CLIs

Any argv template works; these are the lanes the example config ships:

| Tag | Binary | Notes |
|-----|--------|--------|
| `cursor` | [`agent`](https://cursor.com/docs/cli/overview) (Cursor Agent CLI) | `-p --force --trust --approve-mcps --sandbox disabled`. Auth: `agent login` or `CURSOR_API_KEY`. Install puts the binary in `~/.local/bin` (not on the default GUI/launchd PATH) — the dispatcher prepends that dir automatically. |
| `hermes` | [`hermes`](https://github.com/nousresearch/hermes-agent) | House lane: `hermes -z` pinned to the local `ollama-launch` provider + Home Assistant toolset. `worktree: false` (no git). Tag `[hermes][auto]`. |
| `doctor` | `agent` (same CLI as cursor) | Home Doctor: inspect `apple-tasks doctor` + Hermes gateway/cron, notify on salient failures, PR or `[hermes]` follow-up only on repeat. `worktree: true`, 15 min. Tag `[doctor][apple-mcp][auto]`. Recurrence is daily — EventKit has no hourly FREQ. |
| `claude` | `claude` | `-p --permission-mode acceptEdits` |
| `antigravity` | `agy` | sandbox + skip-permissions |
| `triage` | `agy` / `"local"` | cheap classifier, or on-device via `triage.agent: "local"` |
| *(BYOM)* | — | `"llm": { … }` OpenAI-compatible profile (no tools) |

Prefer apple-tasks `"worktree": true` over Cursor's own `-w` so ledger/GC stay authoritative.

### Always-on dispatch (launchd)

```bash
make install-agent              # every 5 min; seeds agents.json if missing
make install-agent INTERVAL=120 # every 2 min
make uninstall-agent

make install-digest             # daily 07:00 digest --note --push
make install-digest HOUR=7 MINUTE=30
make uninstall-digest
```

`install-agent` writes a LaunchAgent that runs `apple-tasks dispatch` with a
PATH that includes `~/.local/bin` (where `agent` / `claude` / `agy` / `hermes` usually
live). Optional secrets go in `~/.config/apple-tasks/launchd.env` (sourced
before each run — e.g. `export CURSOR_API_KEY=…`). Logs:
`~/.config/apple-tasks/logs/dispatch.*.log`. `doctor` reports
`launchAgent` / `cursorAgent` / `hermes` / `hermesGateway` / `hermesCron` /
`homeAssistant` / `budget` / `agentsConfig`.

The optional `triage` block runs the [on-demand inbox
triage](#on-demand-triage-no-loop) at the start of every dispatch cycle:
untagged captures get classified and routed first, so a voice memo tagged
`[auto]` by the classifier can be dispatched in the same run. Same contract as
standalone triage — the classifier agent only judges; the CLI applies and
audits every mutation. Omit the block to keep triage manual. A triage failure
is reported but never blocks the dispatch pass.

Hardening features (all verified end-to-end; see [docs/dispatcher-v2.md](../docs/dispatcher-v2.md) for
the design):

- **Auto pool** (`modelPrefs.auto`, default hermes → cursor → claude →
  antigravity) — `[auto]` with no provider tag walks available workers.
  Named lane tags still pin. Repo-tagged tasks prefer `worktree: true`
  lanes. Exhausted pool stays queued, never `[failed]`.
- **Budget bandwidth** (`autoBudget`: `"skipRed"` default, `"skipYellow"`,
  `"off"`) — `[auto]`-only walks read `~/.config/budget-tracker/latest.json`
  (15 min max age; missing/stale = fail open). Cursor and Antigravity each
  have **two independent percentage lanes** (`combine: "any"`): Cursor
  models vs Other models, Gemini vs Claude+GPT — the provider is skipped
  only when every lane is over the threshold. Claude session+weekly is
  stacked (`combine: "all"`). Named tags ignore bandwidth. Yellow sorts
  after green when still eligible.
- **Context gates** (per-agent `conditions`: `location` — a named entry in
  `places`, checked against a whereami fix; `power` — `"ac"`/`"battery"` via
  pmset; `maxLoad` — 1-min load average cap) — a task failing a gate stays
  queued untouched (no claim, no `[failed]`) and is reconsidered next pass.
  All reads, no new permissions. Use cases: heavy agents only on AC, personal
  repos only at home, nothing heavy while the machine is busy.
- **Atomic claim** — the ledger row is the dispatch lock, taken with a
  single-statement insert-if-absent, so overlapping dispatchers (cron +
  manual, two shells) can't both run the same task. The `[dispatched]` tag is
  written after the claim and is only the human-visible mirror.
- **Concurrency** (`maxConcurrent`, global and per-agent) — agent runs
  execute in a capped task group; the global default of 1 preserves
  sequential behavior until you opt in. Outcomes are recorded as each run
  finishes, so ledger timestamps are per-run accurate.
- **Result write-back** — when a run finishes, the dispatcher appends a
  trailer to the task's notes (`[dispatch #N] <status> exit=… branch=… log=…`
  plus commit oneliners for succeeded worktree runs) and stores its first
  line in the ledger's `summary` column. Agents are prompted to record their
  own 1–3 sentence outcome first via `apple-tasks update <id> --append-notes`
  (non-destructive; appends a paragraph).
- **Worktree GC** — every pass reclaims finished runs' worktrees: merged
  branches are removed immediately, unmerged succeeded branches are kept and
  surfaced as pending deliverables, failed/timeout worktrees are kept
  `keepFailedWorktreeDays` (default 7) then removed (their branch is deleted
  only if empty). `--no-gc` skips the pass.
- **Notifications** (`notifyOn`: `"failure"` default, `"all"`, `"none"`) — a
  macOS notification with the task title and outcome fires as runs finish.
- **Run logs** — each agent's stdout/stderr is captured to
  `~/.config/apple-tasks/runs/<ledger-id>.log`; the ledger stores the path.
- **Worktree isolation** (`"worktree": true` per agent) — the dispatcher runs
  `git worktree add` in the task's workdir and the agent works on its own
  branch (`agent/<tag>-<ledger-id>`) under
  `~/.config/apple-tasks/worktrees/<ledger-id>`. Output is a branch, never
  edits to the main checkout — this is what makes `acceptEdits` reasonable
  unattended. If worktree creation fails the dispatch is aborted, not run
  unisolated.
- **Timeouts** (`"timeoutMinutes"` per agent) — overrunning agents get
  SIGTERM (SIGKILL after 5s) and the run is marked `timeout`.
- **Reaper** — every dispatch pass first marks ledger rows stuck in
  `running` longer than `--reap-hours` (default 4) as `timeout` and swaps the
  task's `[dispatched]` tag for `[failed]`, recovering from a dispatcher
  killed mid-run. `apple-tasks dispatch --reap-only` runs just this step.
- **Retries** (`maxRetries` / `retryBackoffMinutes`, default off) — `[failed]`
  tasks are re-dispatched up to `maxRetries` times once the backoff has
  elapsed (it scales linearly with the attempt count). After the budget is
  spent the task stays `[failed]` for a human or triage agent.

> **Subscription note (Claude Pro/Max):** the dispatcher invokes the official
> `claude` CLI, which Anthropic permits for scripted/headless use under a
> Pro/Max subscription — provided it's your own account, on your own machine,
> for your own tasks. Dispatched runs draw from your normal session/weekly
> limits, so tune `maxRetries` and `timeoutMinutes` accordingly. Do **not**
> run this as a shared service on one subscription (account sharing violates
> Anthropic's Consumer Terms), and use an API key (`ANTHROPIC_API_KEY`, billed
> pay-as-you-go) for always-on or business deployments. Note the Agent SDK is
> different: it requires API-key auth — subscription OAuth only covers the
> first-party CLI. Terms change; this isn't legal advice — check Anthropic's
> current Consumer Terms before relying on it.

## Siri inbox triage

Reminders sync from Siri, watch, iPhone, and CarPlay — so voice capture anywhere
becomes the front door of the agent queue. "Hey Siri, remind me to fix the login
bug" lands untagged in your default "Reminders" list; triage classifies and
routes it.

### On-demand triage (no loop)

`apple-tasks triage` runs the whole classification in one shot: it spawns the
cheap `triage` agent (an `agents.json` entry, e.g. `agy` on Gemini Flash) to
label each untagged inbox item as agent-work or personal, then **the CLI
applies** the tags and list moves itself (the agent only judges, so it needs no
tool-execution permissions). Default is a dry run:

```bash
apple-tasks triage                 # report proposed routing, change nothing
apple-tasks triage --apply         # apply tags + move agent work to its plan list
apple-tasks triage --inbox Inbox --apply
apple-tasks triage --agent local --apply   # on-device Apple model, no subprocess
apple-tasks triage --notes --apply         # + notes → tasks/events (see below)
```

`--notes` extends the same judge-then-apply pipeline to Apple Notes: the
classifier extracts action items from notes modified since the last scan —
date-bound items become calendar events, actionable work becomes (tagged)
tasks — and the CLI creates them with `from note: <name>` in the item's notes
for provenance. Dedupe is the shared notes-scan watermark, which only
advances on `--apply`, so dry runs are repeatable. MCP: `include_notes: true`
on `triage_inbox`.

`--agent local` classifies with Apple's on-device `SystemLanguageModel`
(FoundationModels, macOS 26+, Apple Intelligence enabled): zero API cost,
offline, and `@Generable` structured output instead of parsing agent stdout.
`doctor` reports availability on its `foundationModels` line. The same value
works in the dispatcher's triage block (`"agent": "local"`) and the MCP tool's
`agent` param. This is the first rung of the escalation ladder: on-device →
cheap cloud classifier (`agy` on Flash) → Claude.

Also exposed as MCP `triage_inbox` (dry-run by default), a **"Triage Inbox"
button** in the AgentTasks app's activity view, and a Siri/Shortcuts intent —
*"Hey Siri, triage my inbox in AgentTasks."* Agent work is routed to a plan
list; personal items get a `[personal]` tag and stay put. Already-tagged tasks
are never touched.

To run this automatically before every dispatch cycle instead, add a `triage`
block to `agents.json` (see [Dispatcher & audit log](#dispatcher--audit-log)).

### Continuous triage (a loop)

For hands-off classification as items arrive, run it in Claude Code with
`/loop` (or a scheduled agent):

> /loop 30m Triage my reminders inbox: call task_list(list: "Reminders",
> status: "open") and look at tasks with NO tags. For each one, decide whether
> it's actionable agent work or personal. Route agent work with task_update —
> add tags for the agent ([claude]), repo, and model, and move it to the right
> plan list (see plan_list). Tag personal items [personal] and leave them where
> they are. Never touch tasks that already have tags.

Two inbox options:

- **Default "Reminders" list** (zero friction — plain "remind me to X" works).
  The triage rule above only touches untagged items, so personal reminders are
  safe; they just get a `[personal]` tag once.
- **Dedicated "Inbox" list** (`apple-tasks lists add Inbox`) — cleaner
  separation, but Siri capture requires saying "...to my Inbox list".

Time-blocking pairs with this: an agent can read free slots via `event_list`
and book tagged work sessions via `event_create`.

## Mail rule capture (push)

Polling `mail_scan` has latency; Mail rules are push. `make mail-rule`
compiles `tools/mail-rule-capture.applescript` into Mail's sandboxed
scripts folder, then attach it once: **Mail > Settings > Rules > Add Rule >
"Run AppleScript" > apple-tasks-capture** (pick your own matching conditions —
sender, subject, mailbox). Matching incoming messages become `[mail]`-tagged
reminders in the inbox with From/Subject/Message-ID in the notes; triage
treats `[mail]`-only items as untagged, so they get routed like any other
capture (keeping the `[mail]` provenance tag).

Details: all values pass through AppleScript's `quoted form of` (injection
tested); the handler uses raw event codes because `using terms from
application "Mail"` doesn't compile on macOS 27 beta 3; Mail must be running
for rules to fire; the first capture may show a Reminders permission prompt
for Mail's rule runner. `doctor` reports install status on its `mailRule`
line. Smoke-test without waiting for mail:

```bash
osascript "$HOME/Library/Application Scripts/com.apple.mail/apple-tasks-capture.scpt"
```

## Capture channels (screenshots, drop-folder)

Two more front doors into the inbox, both watermarked like `notes scan` (the
stored watermark auto-advances; `--since` overrides statelessly):

```bash
apple-tasks screenshots scan                 # OCR new images in ~/Desktop
apple-tasks screenshots scan --dir ~/Shots --since 2026-07-01
apple-tasks files scan                       # .txt/.md in iCloud Drive/AgentInbox
apple-tasks files scan --archive             # + move processed files to done/
```

- **`screenshots scan`** turns the "screenshot it to deal with later" habit
  into real capture: on-device Vision text recognition per new image (`png`,
  `jpg`, `heic`, …), emitting `{file, modified, text}`. Free, offline, no TCC
  beyond folder access. The Photos library is deliberately out of scope
  (separate permission + heavier API) — point it at a folder of saved images.
- **`files scan`** is the universal escape hatch: any device drops a `.txt`/
  `.md` into the iCloud `AgentInbox` folder (share sheet, Files app,
  Scriptable, a laptop), and this emits `{file, modified, content}`. Good for
  long pasted text, forwarded snippets, code — anything awkward to say to
  Siri. `--archive` moves processed files into `done/` so they aren't
  re-read (belt-and-suspenders with the watermark); iCloud placeholders are
  materialized before reading.

Feed either output to triage: the agent decides task/event/noise and files it
with the source path as provenance. `doctor` reports the drop-folder path.

## Morning digest

`apple-tasks digest` is a deterministic aggregation (no model, safe to run
unattended): agent activity since yesterday (audit log), dispatch outcomes,
tasks due today (with #19 URL linkbacks to PRs), and today's calendar.

```bash
apple-tasks digest                # JSON to stdout
apple-tasks digest --note         # + write it as a new Apple Note
apple-tasks digest --note --push  # + one-line summary to your ntfy topic
```

Schedule it for coffee time (cron/launchd):

```bash
make install-digest   # preferred — LaunchAgent at 07:00
# or cron:
# 0 7 * * * /path/to/cli/.build/release/apple-tasks digest --note --push
```

Open Notes on your phone over breakfast and see what your agents did
overnight and what's on deck. Also exposed as the MCP `digest` tool, and as a
Siri/Shortcuts intent in AgentTasks — *"Hey Siri, what did my agents do in
AgentTasks?"* speaks the dispatch outcomes, action count, due tasks, and
calendar load.

## iOS Capture Shortcut

You can create an iOS Shortcut to capture agent tasks directly from your iPhone, Apple Watch, or via the Action Button, without needing any custom iOS apps. The task will be added natively to your `Code Tasks` list in Reminders, which syncs to your Mac via iCloud, where the dispatcher picks it up.

### Build Recipe

Create a new Shortcut in the iOS **Shortcuts** app named **"Agent Task"**:

1. **List** (Define the available agents):
   - Add items: `cursor`, `claude`, `antigravity` (or whatever agents you have configured).
2. **Choose from List**:
   - Prompt: `Agent?`
   - Select: `List` (from the previous step).
3. **List** (Define the available repository tags matching your `workdirs` configuration):
   - Add items: `apple-mcp`, `repo2`, etc.
4. **Choose from List**:
   - Prompt: `Repository?`
   - Select: `List` (from the previous step).
5. **Ask for Input**:
   - Prompt: `What is the task?`
   - Input Type: `Text`
6. **Text** (Compose the final reminder title):
   - Type: `[Chosen Item][Chosen Item 2][auto] Provided Input`
   - *Example flow*: If you select `cursor` and `apple-mcp`, and type `Fix typos in readme`, this block will compile to:
     `[cursor][apple-mcp][auto] Fix typos in readme`
7. **Add New Reminder**:
   - Add: `Text` (the composed text from the previous step)
   - To: `Code Tasks` (or your configured Reminders list)
   - Set other fields (e.g. priority, due date) if desired.

### Usage

- **Siri**: Say *"Hey Siri, run Agent Task"*. Siri will prompt you for the agent, repository, and task description.
- **Action Button / Back Tap**: Assign the **Agent Task** shortcut to the Action Button (iPhone 15 Pro+) or a Back Tap gesture for one-tap voice/text capture.
- **Apple Watch**: Run the shortcut from the Shortcuts app on your watch or add it as a watch face complication for instant capturing.

> [!NOTE]
> **iCloud Sync Latency**: iOS Reminders sync to your Mac via iCloud. There is typically a 5 to 30-second sync latency before the reminder appears in your Mac's Reminders app. Once synced, the next run of the Mac dispatcher (`apple-tasks dispatch`) will pick up the task and invoke the agent in the correct work directory.

