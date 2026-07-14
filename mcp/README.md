# apple-tasks MCP server

A thin MCP (Model Context Protocol) server over the `apple-tasks` Swift CLI.
Every tool shells out to the CLI binary — the server adds no state and no
logic of its own beyond argument mapping and output schemas. Build and
concepts (tags, plans, dispatcher, capture channels) are documented in the
[repo README](../README.md).

## Setup

```bash
cd mcp && bun install
```

Register with Claude Code:

```bash
claude mcp add apple-tasks -- bun /Users/andrewcollier/Code/apple-mcp/mcp/src/server.ts
```

The server invokes the Swift binary at `.build/release/apple-tasks`
(relative to the repo). Environment:

- `APPLE_TASKS_BIN` — override the CLI binary path.
- `APPLE_TASKS_FINDMY_PYTHON` — override the FindMy sidecar's Python
  (auto-detects `~/.config/apple-tasks/findmy/venv`).
- The server passes `APPLE_TASKS_CALLER=mcp` so every mutation is
  attributed to MCP in the audit log.

macOS permissions (Reminders, Calendar, Contacts, Location, Automation,
Full Disk Access) are granted **per host process** — granting your terminal
does not grant your MCP host. Run the `doctor` tool to see what the current
host actually has.

## Structured output

Every JSON-emitting tool declares an `outputSchema` and returns
`structuredContent` alongside the plain-text JSON (IDEAS #35). The schemas
mirror the Swift CLI's output structs (`TaskOut`, `EventOut`, `DoctorOut`,
…) — the server adds no fields of its own. Tools whose CLI output is a
top-level array nest it under a named key (`tasks`, `events`, `items`, …)
because `structuredContent` must be an object. Free-form tools
(`shortcut_run`, `run_log`) intentionally stay text-only.

## Tools (43)

**Tasks** — `task_list`, `task_show`, `task_create`, `task_update`,
`task_complete`, `task_uncomplete`, `task_delete`. Tags become `[tag]`
title prefixes; ids accept local or sync-stable external identifiers.
`task_create`/`task_update` take a `recurrence` RRULE subset
(`FREQ=WEEKLY;BYDAY=MO`); completing a recurring task rolls it to the next
occurrence (`recurred: true`, still open, next due date).

**Plans** — `plan_list`, `plan_create` (a plan = a Reminders list).

**Events** — `event_list`, `event_create` (also takes `recurrence`),
`event_update`, `event_delete`, `calendar_list`.

**Notes & Mail** — `notes_scan`, `mail_scan`, `mail_show` (read-only),
`note_create` (new notes only — existing notes are never edited).

**Capture scans** (all watermarked; feed the output to triage) —
`screenshots_scan` (on-device Vision OCR), `files_scan` (text dropped in
an iCloud inbox folder), `audio_scan` (on-device Speech transcription),
`readinglist_scan` (Safari Reading List; needs Full Disk Access).

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
`findmy_locate` (AirTags via the optional FindMy.py sidecar — setup in the
repo README).

**Triage & digest** — `triage_inbox` (classify + route untagged inbox
items; dry-run by default), `digest` (agent activity + dispatch outcomes +
due today + calendar; `note: true` writes an Apple Note, `push: true`
sends a one-line ntfy summary).

**Introspection** — `audit_log` (who did what, when, as whom), `doctor`
(permission + config diagnostics).
