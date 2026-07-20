# AgentTasks

> **Product 2 of 2** in this monorepo — the human / Siri ops app.
> It does **not** reimplement Reminders access. Every action shells out to the
> [`apple-tasks` CLI](../../cli/). See [../../docs/architecture.md](../../docs/architecture.md).

macOS app that exposes the agent task queue to Siri, Shortcuts, and Spotlight,
and provides a small **ops console** window for activity + dispatch control.
Use it when CLI agent sessions (e.g. Cursor `agent`) don’t show up in the IDE —
run logs and the ledger live here (and in `~/.config/apple-tasks/`).

```
"Hey Siri, triage my inbox in AgentTasks"
"Hey Siri, what did my agents do in AgentTasks?"
"Hey Siri, remind me to … in AgentTasks"
```

## Ops console (window)

| Tab | What it shows | Actions |
|-----|---------------|---------|
| **Activity** | Audit log (`apple-tasks log`) | Filter by command type, caller (agents/mcp/launchd/…), failures; Triage Inbox |
| **Dispatches** | Ledger (`apple-tasks dispatches`) | Status filter; **Dry Run** / **Dispatch Now**; **Open Log** for a run |

**Dispatch Now** is the same as `apple-tasks dispatch` / the LaunchAgent from
`make install-agent` — it can launch agents and consume their budgets. Prefer
Dry Run first. Optional `APPLE_TASKS_BIN` overrides the CLI path.

## Relationship to the CLI / MCP

| Concern | Lives in |
|---------|----------|
| EventKit reads/writes, dispatch, triage apply, audit DB | `cli/` (`apple-tasks`) |
| Agent tool surface | `mcp/` |
| Siri / Shortcuts / Spotlight / ops UI | **this app** |

## Build

Requires a recent Xcode (Reminders / Notes domain schemas need the Xcode 27+
SDK). Prefer Xcode-beta when present — `build.sh` sets `DEVELOPER_DIR` for you.

```bash
# from repo root
make            # build the CLI the app shells to
make app        # → apps/AgentTasks/build/AgentTasks.app + LaunchServices register

# or
cd apps/AgentTasks && ./build.sh
```

First launch prompts for Reminders (and other) TCC for **this app’s** process —
separate from Terminal / your MCP host. Run `apple-tasks doctor` from each host
if something mysteriously fails.

## What’s included

- **Ops console** — Activity + Dispatches tabs (`Sources/OpsConsole.swift`).
- **Reminders domain schemas** — create / update / delete reminders & lists
  (`Sources/SchemaIntents.swift`), mapped onto the CLI’s `[tag]` convention.
- **Notes domain** — create note via `apple-tasks notes create`
  (`Sources/NotesSchemaIntents.swift`).
- **Custom intents** — Check Agent Tasks, Add Agent Task, Triage Inbox,
  Agent Status (digest-style spoken summary).
- **Spotlight** — open tasks donated as `IndexedEntity` on launch.

There is no Xcode project: `build.sh` compiles with `swiftc`, runs
`appintentsmetadataprocessor`, and ad-hoc signs.

## Kicking off work

1. Capture (Siri → this app, or plain Reminders / iOS Shortcut).
2. Triage (button / intent here, or `apple-tasks triage` / MCP `triage_inbox`).
3. Dispatch — **Dispatches → Dispatch Now**, `make install-agent` (interval),
   or a supervisor agent via MCP `dispatch_run`.
