# Architecture — two products, one monorepo

This repo is a monorepo for **two related products** that share Apple Reminders
as the human-visible task queue.

```
┌─────────────────────────────────────────────────────────────────┐
│  Humans (Siri / Shortcuts / Reminders.app / watch / Action Btn) │
└────────────────────────────┬────────────────────────────────────┘
                             │ iCloud Reminders
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Product 2 — AgentTasks (apps/AgentTasks)                       │
│  Ops / Siri surface: triage inbox, agent status, create tasks   │
│  Shells out to the CLI. Does not reimplement EventKit.          │
└────────────────────────────┬────────────────────────────────────┘
                             │ apple-tasks …
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Product 1 — apple-tasks CLI + MCP (cli/, mcp/)                 │
│  Agent-facing API: tasks, plans, events, dispatch, triage, …    │
│  Swift CLI is the source of truth; MCP is a thin argv wrapper.  │
└────────────────────────────┬────────────────────────────────────┘
                             │ spawn agents / worktrees
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Coding agents (claude, etc.) — consume MCP tools, complete work│
└─────────────────────────────────────────────────────────────────┘
```

## Product 1 — agent API (`cli/` + `mcp/`)

**Who uses it:** coding agents (and any script).

**What it is:** a dumb, fast, JSON-speaking Swift CLI over EventKit / JXA /
Contacts / Vision, plus an MCP server that shells out to that binary.

**Rules:**

- The CLI stays judgment-free. Agents (or the triage classifier) decide;
  the CLI applies and audits.
- Every mutation is audited to `~/.config/apple-tasks/apple-tasks.db`.
- The MCP server must not grow business logic — argv in, JSON out.

`dispatch`, `triage`, and `digest` live in the CLI because they are
automation entrypoints that still speak JSON and stay headless. Product 2
(and launchd/cron) *invoke* them; they are not a second implementation.

## Product 2 — ops app (`apps/AgentTasks`)

**Who uses it:** you (via Siri, Shortcuts, the menu/activity UI).

**What it is:** a thin App Intents macOS app that exposes the queue to Siri /
Spotlight and provides human-facing controls (triage, status). It always
shells to `apple-tasks` via `APPLE_TASKS_BIN` (or the monorepo build path).

**Rules:**

- No parallel EventKit stack. If the CLI can’t do it, add it to the CLI first.
- App Intents schemas (Reminders, Notes, …) are the Siri integration path.

## Shared conventions

Documented fully in [`cli/README.md`](../cli/README.md):

- A **plan** = a Reminders list; a **task** = a reminder in it.
- Tags are leading `[tag]` title prefixes (EventKit has no public native tags).
- Config and state live under `~/.config/apple-tasks/` (never in the repo).

## Layout

| Path | Role |
|------|------|
| `cli/` | Swift package: `apple-tasks` + optional `apple-tasks-private` |
| `mcp/` | Bun MCP server wrapping the CLI |
| `apps/AgentTasks/` | macOS App Intents app (ops / Siri) |
| `tools/` | Sidecars & helpers (Find My, Mail rule script) |
| `research/` | Spikes not yet productized |
| `docs/` | Design notes, roadmap, this file |

## Build entrypoints

```bash
make          # CLI + private helper → cli/.build/release/
make mcp      # bun install in mcp/
make app      # build + register AgentTasks.app
make betacheck
```
