# apple-tasks MCP server

> **Product 1 of 2** — thin MCP wrapper over the [`../cli`](../cli) Swift binary.
> See [../docs/architecture.md](../docs/architecture.md).

Agents talk to this server; every tool shells out to `apple-tasks` with
`APPLE_TASKS_CALLER=mcp`. No business logic lives here.

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
| `APPLE_TASKS_FINDMY_PYTHON` | Python for the Find My sidecar |

TCC grants are **per host process**. If tools fail after working in Terminal,
run the `doctor` tool from the MCP host.

## Tools (35)

- **Tasks:** `task_list`, `task_show`, `task_create`, `task_update`,
  `task_complete`, `task_uncomplete`, `task_delete`
- **Plans:** `plan_list`, `plan_create`
- **Events:** `event_list`, `event_create`, `event_update`, `event_delete`,
  `calendar_list`
- **Notes / Mail:** `notes_scan`, `note_create` (new notes only),
  `mail_scan`, `mail_show` (read-only)
- **Capture:** `screenshots_scan`, `files_scan`
- **Contacts (read-only):** `contact_search`, `contact_show`
- **Bridges:** `shortcut_list`, `shortcut_run`, `notify`
- **Dispatcher ops:** `dispatch_run` (dry-run by default; refuses recursive
  dispatch when `APPLE_TASKS_CALLER` is `agent:*`), `dispatch_list`, `run_log`
- **Location:** `whereami`, `findmy_devices`, `findmy_locate`
- **Triage / digest:** `triage_inbox`, `digest`
- **Introspection:** `audit_log`, `doctor`

Full behavioral docs live in [`../cli/README.md`](../cli/README.md).
