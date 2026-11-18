# iOS bridge — tree ownership and serve API

The native iOS app (`~/ios-app`, AgentBridge) talks to this monorepo over
Tailscale. This file is the Phase 0 gate for apple-mcp.

## Which tree is live

| Path | Role |
|------|------|
| Working checkout | Where edits land. `make install` copies a signed `apple-tasks` into `~/.local/bin` (override with `BINDIR`). That copy is what launchd should run, not `cli/.build/release/apple-tasks`. |
| `~/.local/bin/apple-tasks` | **Installed.** `com.apple-tasks.dispatch` should point here. Reinstall after a merge with `make install` from the checkout you want to ship. |

Sync procedure if both trees must stay:

1. Commit in `~/apple-mcp`.
2. Merge or cherry-pick into `~/Code/apple-mcp` (or the reverse), never edit both blindly.
3. `make install` from the checkout you want to ship, and `make app` if the menu-bar app changed.
4. `launchctl print gui/$(id -u)/com.apple-tasks.dispatch` — ProgramArguments must be the installed binary (`~/.local/bin/apple-tasks` unless `BINDIR` says otherwise), not `cli/.build/release/apple-tasks`.

## `apple-tasks-server`

New executable in `server/`. It does **not** import EventKit. It execs the
existing `apple-tasks` CLI (same pattern as AgentTasks `CLI.run`).

- Bind: Tailscale IPv4 (`tailscale ip -4`) or `127.0.0.1`. `0.0.0.0` requires `--unsafe-lan-bind`.
- Auth: `Authorization: Bearer` matching `APPLE_TASKS_SERVE_TOKEN` or `~/.config/apple-tasks/serve.json`.
- Install: `make install-server` → `~/.local/bin/apple-tasks-server`. Direct: `./server/.build/release/apple-tasks-server`.
- Routes: see `server/README.md`.

SQLite (`~/.config/apple-tasks/apple-tasks.db`) remains the default ledger.
Supabase is a later authenticated remote ledger — not part of the v1 server.

## AuditDB inventory

See [auditdb-inventory.md](auditdb-inventory.md). Do not invent a six-method
`LedgerStore` stub; any backend switch must cover every current caller.
