# Task recipes

JSON templates for AgentTasks **Add Task** (and `apple-tasks add`).

## Schema

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Filename stem; `[a-z0-9_-]` |
| `name` | string | Shown in the recipe picker |
| `description` | string? | Short blurb |
| `title` | string | Task title (no `[tag]` prefixes) |
| `notes` | string? | Reminders notes / agent instructions |
| `list` | string? | Reminders list name |
| `agent` | string? | Lane tag (`cursor`, `claude`, …). Omit or `"auto"` to let dispatch pick any available worker (`modelPrefs.auto`). |
| `workdir` | string? | `agents.json` workdirs tag |
| `tags` | string[]? | Extra title tags (not agent/workdir/auto) |
| `priority` | string? | `none` \| `low` \| `medium` \| `high` |
| `includeAuto` | bool? | Default `true` — tag `[auto]` for dispatch |
| `dueTime` | string? | `HH:mm` local; first due = next that clock |
| `dueOffsetDays` | int? | Days from today (default `0`) |
| `recurrence` | string? | RRULE subset (`FREQ=DAILY`, …) — requires due. EventKit has no `FREQ=HOURLY`; standing monitors use daily (see `home-doctor.json`). |

Live copies: `~/.config/apple-tasks/recipes/`. AgentTasks seeds bundled examples
there on first open (missing ids only).

Import / export from the Add Task sheet, or copy JSON into that folder.
