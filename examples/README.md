# examples/

Starter configs — copy into `~/.config/apple-tasks/`, never commit your real ones.

| File | Purpose |
|------|---------|
| `agents.json` | Dispatcher lanes: **cursor** (Cursor Agent CLI), claude, antigravity/agy, triage |

```bash
mkdir -p ~/.config/apple-tasks
cp examples/agents.json ~/.config/apple-tasks/agents.json
# edit workdirs + which agents you actually have installed
apple-tasks dispatch --dry-run
```

## Cursor Agent CLI lane

Tag: `[cursor]`. Binary: `agent` (install via `curl https://cursor.com/install -fsS | bash`).

Headless flags used in the example:

| Flag | Why |
|------|-----|
| `-p` / `--print` | Non-interactive; tools (write/shell) enabled |
| `--force` | Auto-approve tool calls (alias: `--yolo`) |
| `--trust` | Skip workspace trust prompt in print mode |
| `--approve-mcps` | Auto-approve MCP servers |
| `--sandbox disabled` | Match worktree isolation from apple-tasks, not Cursor's sandbox |

The Cursor installer puts `agent` in `~/.local/bin`, which is **not** on the
default PATH for GUI apps or launchd (they never source `.zshrc`). The
dispatcher prepends `~/.local/bin` (and Homebrew) when spawning agents, so a
bare `"agent"` command works. Absolute path from `which agent` also fine.

Auth: `agent login`, or set `CURSOR_API_KEY` in the environment. For launchd,
put the key in `~/.config/apple-tasks/launchd.env` (see `make install-agent`)
or your login keychain session after an interactive `agent login`.

Prefer apple-tasks `"worktree": true` over Cursor's own `-w` flag so the
dispatch ledger / GC stay authoritative.
