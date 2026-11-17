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
make install         # sign + copy both into ~/.local/bin (BINDIR=/PREFIX= to override)
make mcp             # bun install for the MCP server
make app             # make install, then build → /Applications/AgentTasks.app
make install-agent   # make install + LaunchAgent: dispatch every 5 min (seeds examples/agents.json)
```

### Deploy path

launchd (dispatch and digest), the AgentTasks app and the Mail rule run the
**installed** copy, `~/.local/bin/apple-tasks`, plus the `apple-tasks-private`
helper next to it. They never run `cli/.build/`. Building in a checkout, a
worktree or on a branch therefore leaves the live dispatcher alone until you run
`make install` from the checkout you want live. `make install` replaces each
file atomically, so a running dispatch pass never sees a half-copied binary.
`make cli` stamps the git commit into the binary (`apple-tasks --version`
prints `0.1.0 (commit <sha>)`, with `-dirty` when `cli/` had uncommitted
changes). `apple-tasks doctor` then reports `deployment.launchdCommit`
against the source HEAD. A plain `swift build` has no stamp and reports
`unknown`, and doctor falls back to comparing file modification times.

**Migrating an existing install** (anything set up before this change, whose
LaunchAgent points at `cli/.build/release/apple-tasks` or whose
`~/.local/bin/apple-tasks` is a symlink into the build directory). Do this
once, from the checkout you want live:

```bash
make install-agent    # installs ~/.local/bin copies (replacing old symlinks), rewrites + reloads the plist
make install-digest   # only if you use the morning digest
make app              # only if you use AgentTasks.app, so it stamps the installed path
apple-tasks doctor | jq .deployment   # launchdBinary should be ~/.local/bin/apple-tasks
```

TCC grants (Reminders, Calendar, Automation) follow the code signature. With
the `make sign-identity` certificate they carry over to the new path. With
ad-hoc signatures, expect macOS to ask for Reminders/Automation access again
the first time the installed copy runs.

Agent lanes (tag tasks `[cursor]`, `[claude]`, …): see [`examples/agents.json`](examples/agents.json).

Register the MCP server (adjust the path):

```bash
claude mcp add apple-tasks -- bun /absolute/path/to/apple-mcp/mcp/src/server.ts
```

Override the CLI binary with `APPLE_TASKS_BIN` if needed. First run prompts for
Reminders access (TCC is per host process — Terminal ≠ your MCP host).

Ad-hoc signatures change on every rebuild, so TCC (Reminders / Calendar /
Automation) and Keychain ACLs reset. Create a persistent self-signed identity
once — later `make` / `make install` / `make app` pick it up automatically
(`make install` re-signs the installed copies with the same identity):

```bash
make sign-identity   # "AgentTasks Dev" in the login keychain; idempotent
```

You will be prompted for the login keychain password (so `codesign` can use the
key without a GUI dialog). Trusting the cert for code signing is optional and
needs admin; the identity still yields a stable designated requirement without it.

## Docs

| Doc | Contents |
|-----|----------|
| [`cli/README.md`](cli/README.md) | CLI reference, tags convention, dispatch, triage, capture |
| [`mcp/README.md`](mcp/README.md) | MCP tools & registration |
| [`apps/AgentTasks/README.md`](apps/AgentTasks/README.md) | Siri / App Intents ops app |
| [`docs/architecture.md`](docs/architecture.md) | Two-product design |
| [`docs/roadmap.md`](docs/roadmap.md) | Ideas & status |
| [`docs/dispatcher-v2.md`](docs/dispatcher-v2.md) | Dispatcher hardening design |
| [`docs/security.md`](docs/security.md) | Threat model, secrets, publish checklist |

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
