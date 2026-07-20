# apple-tasks

Monorepo for **two products** that turn Apple Reminders into an agent task queue.

| Product | Path | Who uses it |
|---------|------|-------------|
| **apple-tasks** CLI + MCP | [`cli/`](cli/), [`mcp/`](mcp/) | Coding agents (and scripts) |
| **AgentTasks** app | [`apps/AgentTasks/`](apps/AgentTasks/) | You — via Siri, Shortcuts, and the ops UI |

Plans and tasks stay fully visible in Reminders on Mac, iPhone, and watch.
Agents read/write through the CLI/MCP; the AgentTasks app is the human/Siri
surface that *kicks off* triage, status, and (with launchd/cron) dispatch.

```
Siri / watch / Shortcuts ──► Reminders (iCloud)
                                 │
                    AgentTasks app (ops / Siri)
                                 │ shells to
                                 ▼
                    apple-tasks CLI ◄── MCP ◄── coding agents
                                 │
                            dispatch / worktrees
```

Full picture: [`docs/architecture.md`](docs/architecture.md).

## Quick start

```bash
make                 # → cli/.build/release/apple-tasks (+ private helper)
make mcp             # bun install for the MCP server
make app             # build & register AgentTasks.app (optional)
make install-agent   # LaunchAgent: dispatch every 5 min (seeds examples/agents.json)
```

Agent lanes (tag tasks `[cursor]`, `[claude]`, …): see [`examples/agents.json`](examples/agents.json).

Register the MCP server (adjust the path):

```bash
claude mcp add apple-tasks -- bun /absolute/path/to/apple-mcp/mcp/src/server.ts
```

Override the CLI binary with `APPLE_TASKS_BIN` if needed. First run prompts for
Reminders access (TCC is per host process — Terminal ≠ your MCP host).

## Docs

| Doc | Contents |
|-----|----------|
| [`cli/README.md`](cli/README.md) | CLI reference, tags convention, dispatch, triage, capture |
| [`mcp/README.md`](mcp/README.md) | MCP tools & registration |
| [`apps/AgentTasks/README.md`](apps/AgentTasks/README.md) | Siri / App Intents ops app |
| [`docs/architecture.md`](docs/architecture.md) | Two-product design |
| [`docs/roadmap.md`](docs/roadmap.md) | Ideas & status |
| [`docs/dispatcher-v2.md`](docs/dispatcher-v2.md) | Dispatcher hardening design |

## Repo layout

```
cli/                 Swift package — agent API (source of truth)
mcp/                 Bun MCP server — thin wrapper over the CLI
apps/AgentTasks/     macOS App Intents app — human/Siri ops
tools/               Find My sidecar, Mail rule AppleScript
research/            Spikes (Foundation Models / Claude-in-process)
docs/                Architecture, roadmap, design notes
```

## Conventions (shared)

- **A plan = a Reminders list. A task = a reminder in it.**
- **Calendar events use the same `[tag]` convention** as tasks.
- **Tags** are leading `[tag]` title prefixes: `[claude][repo2] Add MFA`.
  Only leading bracket groups count; the CLI/MCP parse them out of titles.
- The CLI stays dumb and JSON-speaking; agents make judgment calls.
- Local config lives in `~/.config/apple-tasks/` (never committed).
