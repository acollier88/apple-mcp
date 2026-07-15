# apple-tasks

Apple Reminders as an agent task queue. A native Swift CLI (EventKit) is the backbone;
a thin MCP server exposes it to agents. Plans and tasks stay fully visible in the
Reminders app on Mac, iPhone, and watch.

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
make            # builds the CLI and the optional native-tags helper
# binaries: .build/release/apple-tasks, .build/release/apple-tasks-private
```

`swift build -c release` builds just the CLI; everything works without the
helper.

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
leaves the reminder un-filed and thus invisible to EventKit (IDEAS #26).
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
apple-tasks list --search "MFA"                    # substring match over title + notes
apple-tasks update <id> --add-tag backend --remove-tag repo2 --title "New title"
apple-tasks update <child-id> --parent <parent-id>   # native subtask (private helper)
apple-tasks update <id> --attach-file ./shot.png --attach-url "https://…"  # attachments (private helper)
apple-tasks show <id> --attachments                # list them (file content needs Full Disk Access)
apple-tasks complete <id>
apple-tasks uncomplete <id>
apple-tasks delete <id>
apple-tasks show <id>
```

All output is compact JSON. Errors go to stderr with exit code ≠ 0.
Task ids accept either the local or sync-stable external identifier.

`add-batch` creates many tasks in one call — a whole triage run's worth —
from a JSON array on stdin (or `--file`). Each item is
`{list, title, tags?, notes?, due?, priority?, url?, recurrence?}`; items
fail independently, so the output separates `created` (full task JSON)
from `failed` (index, title, error):

```bash
echo '[{"list":"Code Tasks","title":"Add MFA","tags":["claude","repo2"]},
       {"list":"Code Tasks","title":"Rotate keys","due":"2026-07-20"}]' \
  | apple-tasks add-batch
```

### Recurrence

`--recurrence` takes an RRULE subset —
`FREQ=DAILY|WEEKLY|MONTHLY|YEARLY;INTERVAL=n;BYDAY=MO,WE;BYMONTHDAY=1,15;UNTIL=yyyy-MM-dd|COUNT=n`
— and requires a due date (the first occurrence anchors the series):

```bash
apple-tasks add --list "Code Tasks" -t claude -t auto \
    --due "2026-07-20 07:00" --recurrence "FREQ=WEEKLY;BYDAY=MO" "Weekly review"
apple-tasks update <id> --recurrence "FREQ=DAILY;INTERVAL=2"   # set/replace
apple-tasks update <id> --clear-recurrence                     # series stops
```

Completing a recurring task rolls it to the next occurrence — same id and
externalId, `recurred: true` in the output, due date advanced — and sheds
the dispatcher lifecycle tags (`[dispatched]`/`[failed]`) so the fresh
occurrence is dispatchable again. Combined with the dispatcher's due-date
gate, a recurring `[claude][auto]` reminder IS a scheduled agent routine:
"every Monday 7am, run the weekly review" with zero dispatcher config.

### Calendar events

Calendar access is a separate macOS permission from Reminders (granted the same way).

```bash
apple-tasks calendars                              # list calendars (+ writable flag)
apple-tasks events list                            # today through +7 days
apple-tasks events list --from 2026-06-11 --to 2026-06-12 -t claude
apple-tasks events add --calendar Home -t claude -t repo2 \
    --start "2026-06-11 09:00" --duration 90 "Deep work: MFA implementation"
apple-tasks events add --start 2026-06-12 "Release day"   # date-only start = all-day
apple-tasks events add --start "2026-07-01 09:00" --duration 30 \
    --recurrence "FREQ=MONTHLY;BYMONTHDAY=1" "Pay rent"   # same RRULE subset as tasks
apple-tasks events update <id> --start "2026-06-11 13:00" --end "2026-06-11 14:30"
apple-tasks events show <id>
apple-tasks events delete <id>
```

`events update`/`delete` operate on single occurrences (`.thisEvent`);
editing a whole series from the CLI is not wired up yet.

### Notes & Mail (read-only, via Apple Events)

Notes and Mail have no public framework; these shell out to JXA. First use may
prompt for Automation permission ("Terminal wants to control Notes/Mail").

```bash
apple-tasks notes scan                       # notes modified since last scan
                                             # (watermark in apple-tasks.db;
                                             #  first run looks back 24h)
apple-tasks notes scan --since 2026-06-01 --folder Work --max-chars 500   # stateless
apple-tasks mail scan --since 2026-06-02 --limit 20    # inbox headers, newest first
apple-tasks mail show <id> --max-chars 2000            # one message with body
```

Bodies come back as plain text (HTML stripped). Password-protected notes are
invisible to scripting. `mail scan` returns `[]` unless Mail.app is actually
syncing the account.

The write half is **drafts only — there is no send path** (IDEAS #37):

```bash
apple-tasks mail draft --to sarah@corp.com --subject "Re: budget" --body "..."
apple-tasks mail draft --reply-to "<CADkT0=abc@mail.gmail.com>" --body-file report.md
```

`--reply-to` accepts the RFC Message-ID a `[mail]`-captured task carries in
its notes (or a numeric id from `mail scan`) and uses Mail's native reply so
threading is preserved; only the inbox is searched. The draft lands in
Mail's Drafts — synced to every device — and a human hits send. Combined
with the #12 mail rule this closes the email loop: mail in → task →
dispatched agent → reply draft + push out. Dispatched `[mail]` tasks get a
prompt line telling the agent to report exactly this way.

AgentTasks also adopts the Notes and Calendar App Intents domains
(macOS 27, `NotesSchemaIntents.swift` / `CalendarSchemaIntents.swift`):
*"Hey Siri, create a note in AgentTasks"* shells to `notes create`, and
*"create an event in AgentTasks"* shells to `events add` (schema fields
not wired through — attendees, alarms, and intent-supplied recurrence —
are accepted and ignored; the CLI itself models recurrence via
`--recurrence`). Mail domain adoption was attempted and descoped — see
IDEAS #29.

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

The MCP server is a thin shell over the CLI — every tool maps to a CLI
invocation, with declared output schemas (`structuredContent`) mirroring
the CLI's JSON. Setup, environment variables, and the full 43-tool catalog
live in **[mcp/README.md](mcp/README.md)**. Quick start:

```bash
cd mcp && bun install
claude mcp add apple-tasks -- bun /Users/andrewcollier/Code/apple-mcp/mcp/src/server.ts
```

## Location: whereami & Find My sidecar

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
~/.config/apple-tasks/findmy/venv/bin/python3 sidecar/findmy-sidecar.py login   # Apple ID + 2FA
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

## Notes-to-tasks triage loop

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

`apple-tasks dispatch` finds open tasks tagged with a configured agent AND
`[auto]`, marks them `[dispatched]`, and launches the agent with a prompt
containing the task details and self-complete instructions. Config at
`~/.config/apple-tasks/agents.json`:

```json
{
  "agents": {
    "claude": {
      "command": ["claude", "-p", "{prompt}", "--permission-mode", "acceptEdits"],
      "worktree": true,
      "timeoutMinutes": 60,
      "maxConcurrent": 1,
      "conditions": { "location": "home", "power": "ac", "maxLoad": 8,
                      "time": { "notBetween": ["22:00", "07:00"] },
                      "idleMinutes": 15, "blockingApps": ["zoom.us", "Keynote"] }
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
  "notifyOn": "failure"
}
```

The first task tag matching a `workdirs` key sets the agent's working
directory. Dedupe is enforced by both the dispatch ledger and the
claim tags, which are **hostname-scoped** (`[dispatched:mbp]`,
`[failed:mbp]`) so two Macs syncing the same Reminders can each run a
dispatcher: any Mac's claim blocks re-dispatch, but a dispatcher only
reaps/retries its *own* claims (bare legacy `[dispatched]`/`[failed]`
tags count as its own). The ledger stays per-machine, so iCloud sync lag
is still the only claim channel between Macs — prefer giving each agent
tag a single home Mac for truly contested queues. Tasks with a **future due date stay queued
until due** (dry-run reports them as "scheduled") — on an agent task, a due
date means "run at", not "by". That plus recurrence is the scheduled-routine
pattern: a `[claude][auto]` reminder due Monday 7am with
`--recurrence "FREQ=WEEKLY;BYDAY=MO"` runs weekly, forever. Always test
routing with `apple-tasks dispatch --dry-run` first.
`--watch`/launchd mode is on the roadmap (IDEAS.md #7).

The optional `triage` block runs the [on-demand inbox
triage](#on-demand-triage-no-loop) at the start of every dispatch cycle:
untagged captures get classified and routed first, so a voice memo tagged
`[auto]` by the classifier can be dispatched in the same run. Same contract as
standalone triage — the classifier agent only judges; the CLI applies and
audits every mutation. Omit the block to keep triage manual. A triage failure
is reported but never blocks the dispatch pass.

Hardening features (all verified end-to-end; see docs/dispatcher-v2.md for
the design):

- **Context gates** (per-agent `conditions`: `location` — a named entry in
  `places`, checked against a whereami fix; `power` — `"ac"`/`"battery"` via
  pmset; `maxLoad` — 1-min load average cap; `time` — a quiet-hours window
  `{"notBetween": ["22:00", "07:00"]}`, local time, wrapping midnight;
  `idleMinutes` — user must have been away from keyboard/mouse at least this
  long; `blockingApps` — hold while any listed app is running, matched by
  bundle id or app name, case-insensitive) — a
  task failing a gate stays queued untouched (no claim, no `[failed]`) and is
  reconsidered next pass. All reads, no new permissions. Use cases: heavy
  agents only on AC, personal repos only at home, nothing heavy while the
  machine is busy, while you're presenting or on a call, or at 2am.
- **Subtask dependencies** — a parent task with open native subtasks
  (`update <child> --parent <parent>`) stays queued until every subtask
  completes; subtasks dispatch on their own agent tags. Plan shape: parent
  `[claude][auto] Ship feature X` with per-step subtasks, possibly assigned
  to different agents — the parent runs last, as the integrator. Read via
  the private helper (one call per pass); if the helper is unavailable the
  gate simply doesn't fire.
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

### Dispatcher lanes: web actions

A lane is just an agents.json entry whose agent carries extra capability —
no dispatcher code involved. The `[web]` lane gives a task a
browser-capable agent (Playwright MCP, or any browser MCP you trust):

```json
"web": {
  "command": ["claude", "-p", "{prompt}",
              "--permission-mode", "acceptEdits",
              "--mcp-config", "{\"mcpServers\":{\"playwright\":{\"command\":\"npx\",\"args\":[\"@playwright/mcp@latest\"]}}}"],
  "timeoutMinutes": 20,
  "maxConcurrent": 1,
  "promptTemplate": "You have been dispatched a web task from AgentTasks.\nTask id: {id}\nTitle: {title}\nNotes: {notes}\nUse your browser tools to do the task, READ-ONLY by default. Before ANY transactional step (purchase, booking, sending a message, submitting a form that changes state), you MUST request human approval: apple-tasks approve request \"<what you want to do>\" --task {id}, then poll apple-tasks approve check <token> --wait-seconds 240 and proceed only on approved. When finished: apple-tasks update {id} --append-notes \"<outcome>\" then apple-tasks complete {id} and apple-tasks update {id} --remove-tag {claimTag}"
}
```

Then `[web][auto] Check if the refund from Acme posted` dispatches a
browser agent on the next pass. Safety posture, deliberately conservative:

- **Never** exempt the web lane from `requireAutoTag` — a `[web]` task runs
  only because you also said `[auto]`.
- **Nothing transactional runs unattended.** The prompt template routes
  every state-changing step through the [ntfy approval
  protocol](#approvals-human-in-the-loop) — you get an
  Approve/Reject button on your phone; the agent proceeds only on approve.
  The initial allowance for unattended web writes is: none.
- Timeouts matter more here (pages hang); keep `timeoutMinutes` short and
  `maxConcurrent` at 1.

### Dispatcher lanes: Google Workspace

Same pattern for `[google]`-tagged tasks, using **Google's official managed
MCP servers** (Gmail, Calendar, Drive, Chat, People — GA since May 2026;
auth inherits your own Google permissions via OAuth on first use). Don't
build a Google CLI sibling — Google is territorial about third-party
Workspace tooling; wiring their own servers in keeps this personal-use and
unbranded:

```json
"google": {
  "command": ["claude", "-p", "{prompt}",
              "--permission-mode", "acceptEdits",
              "--mcp-config", "~/.config/apple-tasks/google-mcp.json"],
  "timeoutMinutes": 15,
  "maxConcurrent": 1
}
```

with `google-mcp.json` pointing at the official remote servers (see
Google's current MCP docs for the endpoint URLs — they're remote/HTTP
servers, not local processes). Then `[google][auto] Add prep notes to
today's meetings` — the `[gemini][calendar]` example this project started
with — works with zero code. The same safety posture as the web lane
applies: sending mail or modifying someone's calendar is transactional —
route it through the approval protocol in your promptTemplate. A
watermarked `gmail scan` capture feed (fixing the "Mail.app isn't syncing"
hole) stays on the roadmap; it needs Gmail API OAuth credentials of its
own, so it ships separately (IDEAS #42).

## Notifications & quiet hours

`apple-tasks notify <title> <message> [--push]` shows a macOS banner;
`--push` also sends it via [ntfy](https://ntfy.sh) so it reaches your
phone/watch. The dispatcher pushes failures/timeouts automatically when
configured (banners follow `notifyOn`). Config at
`~/.config/apple-tasks/notify.json` (never commit it — topic names are the
secret):

```json
{
  "ntfy": { "topic": "your-unguessable-topic", "server": "https://ntfy.sh" },
  "quietHours": { "notBetween": ["22:00", "07:00"] },
  "approvalsReplyTopic": "your-unguessable-topic-approvals"
}
```

`quietHours` (times are local; start > end wraps midnight) suppresses
banner + push inside the window — the command still exits 0 and the
suppression is audited; `--force` overrides for priority pings. An invalid
window fails open, so a config typo can't mute notifications. The same
window shape works as a dispatch `time` condition (see context gates).

## Approvals (human-in-the-loop)

`approve` turns `[auto]` from a binary pre-grant into a real approval
protocol: an agent mid-run can ask before doing something consequential,
and you answer from your phone or watch.

```bash
apple-tasks approve request "Send the reply draft to Sarah?" --task <id>
# → pushes an ntfy notification with [Approve] [Deny] buttons, emits a token
apple-tasks approve check <token> --wait-seconds 600   # block until answered
apple-tasks approve answer <token> approve|deny        # answer from the Mac
apple-tasks approve list --status pending
```

The buttons POST `approve <token>` / `deny <token>` to a **reply topic**
(default `<topic>-approvals`) and `check` polls it — no local endpoint,
nothing exposed on the Mac. Requests expire (default 240 min); the first
answer wins (late taps and double answers are rejected); every request and
answer is audited with its caller. Request pushes respect `quietHours`
unless `--force` — a suppressed request still exists and is answerable via
`approve answer` or visible in `approve list`. The MCP server exposes
request/check/list but deliberately **not** answer: an agent approving its
own request would defeat the protocol.

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
compiles `scripts/mail-rule-capture.applescript` into Mail's sandboxed
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

## Capture channels (screenshots, drop-folder, voice notes, Reading List, clipboard)

More front doors into the inbox, all watermarked like `notes scan` (the
stored watermark auto-advances; `--since` overrides statelessly):

```bash
apple-tasks screenshots scan                 # OCR new images in ~/Desktop
apple-tasks screenshots scan --dir ~/Shots --since 2026-07-01
apple-tasks files scan                       # .txt/.md in iCloud Drive/AgentInbox
apple-tasks files scan --archive             # + move processed files to done/
apple-tasks audio scan                       # transcribe voice notes in the inbox folder
apple-tasks reading-list scan                # new Safari Reading List saves
apple-tasks clipboard scan                   # clipboard text, if it changed
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
- **`audio scan`** transcribes voice memos dropped in the same inbox folder
  with on-device Speech recognition, emitting `{file, modified, transcript}`.
  Failed files are retried next scan; `--archive` moves transcribed files to
  `done/`.
- **`reading-list scan`** surfaces new Safari Reading List saves as
  `{title, url, dateAdded, previewText}` so triage can turn saved articles
  into `[read]` tasks. Read-only over `Bookmarks.plist`; the host process
  needs Full Disk Access (`doctor` reports the grant, `--path` overrides for
  testing).
- **`clipboard scan`** makes "copy it to deal with later" a channel: emits
  the clipboard's text as `{ts, content, truncated}` if the pasteboard
  changed since the last scan (at most one clipping per call — there is no
  clipboard history). Privacy rails: password-manager/transient clippings
  (`org.nspasteboard.ConcealedType`) are never surfaced, the first run only
  records a baseline so pre-existing clipboard contents can't leak, and
  clippings are never audit-logged. Deliberately opt-in per run — call it
  from a loop you control, no daemon ships.

Feed any of it to triage: the agent decides task/event/noise and files it
with the source path as provenance. `doctor` reports the drop-folder path.

## Topic watches & web fetch

Standing monitors over the open web — the same watermarked-scan primitive
as the capture channels, pointed outward. Config at
`~/.config/apple-tasks/watches.json`:

```json
{
  "watches": [
    { "name": "swift-blog", "kind": "rss", "url": "https://www.swift.org/atom.xml", "cadenceMinutes": 360 },
    { "name": "pricing-page", "kind": "url", "url": "https://example.com/pricing" }
  ]
}
```

```bash
apple-tasks watch scan            # fetch due watches, emit only NEW items
apple-tasks watch scan --watch swift-blog --force
apple-tasks watch list            # config + last fetch + due now?
apple-tasks web fetch https://example.com --max-chars 4000
```

`rss` watches dedupe by feed entry id (first run seeds the seen-set and
surfaces only the last 24h); `url` watches hash the page body and emit a
"content changed" item (first run records a baseline). Each watch runs on
its own `cadenceMinutes` (default 60); a failed fetch is reported per-watch
and never fatal. Feed the items to triage like any other capture — hits
become `[read]` tasks with the URL in the url field and land in the
morning digest. `web fetch` reduces a page to readable text (scripts and
styles stripped) so web-less lanes — the on-device triage model, in-process
agents — get page context without a browser.

## Morning digest

`apple-tasks digest` is a deterministic aggregation (no model, safe to run
unattended): agent activity since yesterday (audit log), dispatch outcomes,
tasks due today (with #19 URL linkbacks to PRs), and today's calendar.

```bash
apple-tasks digest                # JSON to stdout
apple-tasks digest --note         # + write it as a new Apple Note
apple-tasks digest --note --push  # + one-line summary to your ntfy topic
apple-tasks digest --suggest      # + a Suggestions section (see below)
```

Schedule it for coffee time (cron/launchd):

```cron
0 7 * * * /path/to/.build/release/apple-tasks digest --note --push
```

Open Notes on your phone over breakfast and see what your agents did
overnight and what's on deck. Also exposed as the MCP `digest` tool, and as a
Siri/Shortcuts intent in AgentTasks — *"Hey Siri, what did my agents do in
AgentTasks?"* speaks the dispatch outcomes, action count, due tasks, and
calendar load.

## Proactive suggestions

`apple-tasks suggest` reviews the week's signals — calendar look-ahead,
upcoming contact birthdays, stale tasks (`[read]` saves, lingering claim
tags, long-overdue items), and the last 24h of agent activity — with the
on-device Foundation Models classifier, and **proposes** items:

```bash
apple-tasks suggest                       # {suggestions: [{kind, title, reason, due?}]}
apple-tasks suggest --days 14 --max 5     # wider look-ahead, tighter cap
apple-tasks digest --note --suggest       # proposals as a digest section
```

Kinds: `task` ("Stacy: birthday wish or call"), `event` (a travel block
before a distant appointment), `drop` (an 846-day-old overdue task you're
never doing). **Nothing is auto-created** — same architecture rule as
triage: the model judges, application is a separate explicit act (yours, or
an agent calling `task_create` on proposals you accept). Every suggestion
carries a `reason` citing the signal line it came from. In the digest the
section is best-effort: an unavailable model annotates the JSON
(`suggestError`) instead of failing the 7am run. MCP: `suggest` tool.

## iOS Capture Shortcut

You can create an iOS Shortcut to capture agent tasks directly from your iPhone, Apple Watch, or via the Action Button, without needing any custom iOS apps. The task will be added natively to your `Code Tasks` list in Reminders, which syncs to your Mac via iCloud, where the dispatcher picks it up.

### Build Recipe

Create a new Shortcut in the iOS **Shortcuts** app named **"Agent Task"**:

1. **List** (Define the available agents):
   - Add items: `claude`, `antigravity` (or whatever agents you have configured).
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
   - *Example flow*: If you select `claude` and `apple-mcp`, and type `Fix typos in readme`, this block will compile to:
     `[claude][apple-mcp][auto] Fix typos in readme`
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

