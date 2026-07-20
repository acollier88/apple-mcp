# AgentTasks

> **Product 2 of 2** in this monorepo — the human / Siri ops app.
> It does **not** reimplement Reminders access. Every action shells out to the
> [`apple-tasks` CLI](../../cli/). See [../../docs/architecture.md](../../docs/architecture.md).

macOS app that exposes the agent task queue to Siri, Shortcuts, and Spotlight
via App Intents. Use it to triage the inbox, ask what agents did, and create
tagged tasks by voice — the same queue agents consume over MCP.

```
"Hey Siri, triage my inbox in AgentTasks"
"Hey Siri, what did my agents do in AgentTasks?"
"Hey Siri, remind me to … in AgentTasks"
```

## Relationship to the CLI / MCP

| Concern | Lives in |
|---------|----------|
| EventKit reads/writes, dispatch, triage apply, audit DB | `cli/` (`apple-tasks`) |
| Agent tool surface | `mcp/` |
| Siri / Shortcuts / Spotlight / activity UI | **this app** |

Set `APPLE_TASKS_BIN` if the CLI isn’t at the monorepo default
(`../../cli/.build/release/apple-tasks` relative to this package’s Sources).

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

- **Reminders domain schemas** — create / update / delete reminders & lists
  (`Sources/SchemaIntents.swift`), mapped onto the CLI’s `[tag]` convention.
- **Notes domain** — create note via `apple-tasks notes create`
  (`Sources/NotesSchemaIntents.swift`). Calendar domain was attempted and
  descoped; see [roadmap #29](../../docs/roadmap.md).
- **Custom intents** — Check Agent Tasks, Add Agent Task, Triage Inbox,
  Agent Status (digest-style spoken summary).
- **Spotlight** — open tasks donated as `IndexedEntity` on launch.

There is no Xcode project: `build.sh` compiles with `swiftc`, runs
`appintentsmetadataprocessor`, and ad-hoc signs.

## Kicking off work

This app is the **human front door**. Unattended agent runs are started by the
CLI’s `dispatch` (cron / launchd / `dispatch_run` over MCP), not by a second
runtime inside the app:

1. Capture (Siri → this app, or plain Reminders / iOS Shortcut).
2. Triage (`triage` intent here, or `apple-tasks triage` / MCP `triage_inbox`).
3. Dispatch (`apple-tasks dispatch` on a schedule, or a supervisor agent via MCP).

Wire always-on dispatch with `make install-agent` from the repo root (LaunchAgent
every 5 minutes). Keep this app for voice and visibility.
