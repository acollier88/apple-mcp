# apple-tasks MCP server

> **Product 1 of 2** — thin MCP wrapper over the [`../cli`](../cli) Swift binary.
> See [../docs/architecture.md](../docs/architecture.md).

Agents talk to this server; every tool shells out to `apple-tasks` with
`APPLE_TASKS_CALLER=mcp`. No business logic lives here. Build, tags, dispatcher,
and capture concepts are documented in [`../cli/README.md`](../cli/README.md).

## Setup

```bash
# from repo root
make            # build cli/.build/release/apple-tasks
make mcp        # bun install
```

Register with Claude Code (use an absolute path):

```bash
claude mcp add apple-tasks -- bun /absolute/path/to/apple-mcp/mcp/src/server.ts
```

Env overrides:

| Variable | Purpose |
|----------|---------|
| `APPLE_TASKS_BIN` | Path to the `apple-tasks` binary (default: `../cli/.build/release/apple-tasks`) |
| `APPLE_TASKS_FINDMY_PYTHON` | Python for the Find My sidecar (auto-detects `~/.config/apple-tasks/findmy/venv`) |

TCC grants are **per host process**. If tools fail after working in Terminal,
run the `doctor` tool from the MCP host.

## Structured output

Every JSON-emitting tool declares an `outputSchema` and returns
`structuredContent` alongside the plain-text JSON (IDEAS #35). The schemas
mirror the Swift CLI's output structs (`TaskOut`, `EventOut`, `DoctorOut`,
…) — the server adds no fields of its own. Tools whose CLI output is a
top-level array nest it under a named key (`tasks`, `events`, `items`, …)
because `structuredContent` must be an object. Free-form tools
(`shortcut_run`, `run_log`) intentionally stay text-only.

## Tools (51)

**Tasks** — `task_list`, `task_show`, `task_create`, `task_create_batch`,
`task_update`, `task_complete`, `task_uncomplete`, `task_delete`. Tags
become `[tag]` title prefixes; ids accept local or sync-stable external
identifiers. `task_list` takes a `search` substring filter over title +
notes. `task_create_batch` creates many tasks in one call (a whole triage
run's worth); items fail independently and are reported under `failed`
with their index. `task_create`/`task_update` take a `recurrence` RRULE
subset (`FREQ=WEEKLY;BYDAY=MO`); completing a recurring task rolls it to
the next occurrence (`recurred: true`, still open, next due date).
Attachments (private helper): `task_show` takes `attachments: true`,
`task_update` takes `attach_file`/`attach_url`; dispatched agents get
attachment paths in their prompt (reading file content needs Full Disk
Access on the reading process). Structure (private helper): `task_update`
takes `parent`/`clear_parent` (native subtasks) and `section` (move into a
named section of the task's list, created if needed); `task_show` takes
`section: true` — a plan list can be visually phased in Reminders
(sections = phases, subtasks = steps).

**Plans** — `plan_list`, `plan_create` (a plan = a Reminders list).

**Events** — `event_list`, `event_show`, `event_create` (also takes
`recurrence`), `event_update`, `event_delete`, `calendar_list`.

**Notes & Mail** — `notes_scan`, `mail_scan`, `mail_show` (read-only),
`note_create` (new notes only — existing notes are never edited),
`mail_draft` (new message or threaded reply; drafts only, **no send path
exists** — the human reviews and sends).

**Capture scans** (all watermarked; feed the output to triage) —
`screenshots_scan` (on-device Vision OCR), `files_scan` (text dropped in
an iCloud inbox folder), `audio_scan` (on-device Speech transcription),
`readinglist_scan` (Safari Reading List; needs Full Disk Access),
`clipboard_scan` (clipboard text if changed since last call; concealed/
transient clippings never surfaced, first call records a baseline only).

**Topic watches** (IDEAS #38) — `watch_scan` fetches due RSS/page watches
from `~/.config/apple-tasks/watches.json` and emits only new items;
`watch_list` shows config + state. `web_fetch` reduces a page to readable
text for agents without their own web tools.

**Approvals** (IDEAS #39) — `approval_request` pushes an ntfy notification
with [Approve] [Deny] buttons and returns a token; `approval_check`
(optionally waiting) polls for the human's answer; `approval_list` shows
history. Use before doing anything consequential you were not explicitly
asked to do. There is deliberately **no** MCP tool to answer an approval —
an agent answering its own request defeats the protocol.

**Contacts** (read-only, always) — `contact_search` (name, or email when
the query contains `@`), `contact_show`.

**Bridges** — `shortcut_list`, `shortcut_run` (escape hatch to anything
Shortcuts can do), `notify` (macOS banner; `push: true` also sends via
ntfy — respects the quiet-hours window in `notify.json`).

**Dispatcher ops** — `dispatch_run` (dry-run by default; refuses recursive
dispatch from agent-spawned sessions), `dispatch_list`, `run_log` — a
supervisor agent can reap, retry, and read failure logs over MCP.

**Location** — `whereami` (this Mac, CoreLocation), `findmy_devices` /
`findmy_locate` (AirTags via the optional FindMy.py sidecar — setup in
[`../cli/README.md`](../cli/README.md)).

**Triage & digest** — `triage_inbox` (classify + route untagged inbox
items; dry-run by default), `digest` (agent activity + dispatch outcomes +
due today + calendar; `note: true` writes an Apple Note, `push: true`
sends a one-line ntfy summary, `suggest: true` appends on-device model
proposals), `suggest` (proactive proposals from calendar/birthdays/stale
tasks/agent activity — {kind: task|event|drop, title, reason, due?};
NOTHING is auto-created, apply accepted proposals via task_create).

**Gmail** (IDEAS #42) — `gmail_scan` (watermarked Gmail inbox capture feed,
mirroring `mail_scan`'s shape + `threadId`/`snippet`; first call looks back
24h), `gmail_show` (one message with plain-text body). Read-only OAuth scope
— **no send path exists**; replies belong to the `[google]` dispatcher lane.
Needs a one-time `apple-tasks gmail login` from a terminal (setup in
[`../cli/README.md`](../cli/README.md)).

**GitHub** — `github_sync` (two-way issue sync via the gh CLI: assigned
open issues → [github]-tagged tasks with URL dedupe, closed issues
complete their reminders, `close_issues: true` closes issues for completed
reminders; `dry_run` defaults TRUE from MCP).

**Introspection** — `audit_log` (who did what, when, as whom), `doctor`
(permission + config diagnostics).

Full behavioral docs live in [`../cli/README.md`](../cli/README.md).
