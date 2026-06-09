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

## CLI

```bash
apple-tasks lists                                  # show lists (plans)
apple-tasks lists add "repo2-plan"                 # create a list
apple-tasks add --list "Code Tasks" -t claude -t repo2 \
    --due 2026-06-10 --priority high "Add MFA to sign in page"
apple-tasks list --list "Code Tasks" -t claude     # open tasks tagged claude
apple-tasks list --status all                      # everything, everywhere
apple-tasks update <id> --add-tag backend --remove-tag repo2 --title "New title"
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

## MCP server

```bash
cd mcp && bun install
```

Register with Claude Code:

```bash
claude mcp add apple-tasks -- bun /Users/andrewcollier/Code/apple-mcp/mcp/src/server.ts
```

Tools (18):

- Tasks: `task_list`, `task_create`, `task_update`, `task_complete`, `task_delete`
- Plans: `plan_list`, `plan_create`
- Events: `event_list`, `event_create`, `event_update`, `event_delete`, `calendar_list`
- Notes/Mail (read-only): `notes_scan`, `mail_scan`, `mail_show`
- Bridges: `shortcut_list`, `shortcut_run` (escape hatch to HomeKit/Focus/anything
  Shortcuts can do), `notify` (local notification banner)

The server shells out to the Swift binary at `.build/release/apple-tasks`;
override with the `APPLE_TASKS_BIN` env var.

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

## Siri inbox triage

Reminders sync from Siri, watch, iPhone, and CarPlay — so voice capture anywhere
becomes the front door of the agent queue. "Hey Siri, remind me to fix the login
bug" lands untagged in your default "Reminders" list; a triage agent on a loop
classifies and routes it.

Run it in Claude Code with `/loop` (or a scheduled agent):

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
