# tools/

Optional helpers used by the CLI / MCP — not standalone products.

| Path | Purpose |
|------|---------|
| `findmy/` | FindMy.py sidecar for AirTag location (`findmy_devices` / `findmy_locate`) |
| `mail-rule-capture.applescript` | Mail.app rule → `[mail]` inbox reminders (`make mail-rule`) |
| `launchd/` | LaunchAgent plists + env wrapper (`make install-agent` / `install-digest`) |
| `sign.sh` | One codesign path for the CLI, helper, installed copies and the app ("AgentTasks Dev" when present) |
| `sign-identity.sh` | Creates the persistent "AgentTasks Dev" signing identity (`make sign-identity`) |

## LaunchAgents and the installed binary

The plists in `launchd/` are templates. `make install-agent` / `make install-digest`
run `make install` first, which signs the CLI and its `apple-tasks-private`
helper and copies both into `~/.local/bin` (`BINDIR=` / `PREFIX=` override).
They then substitute `@APPLE_TASKS_BIN@` with that installed path. They never
use `cli/.build/release`, because a `swift build` in any checkout would
otherwise swap the live dispatcher. Each file is staged in a temp directory
inside `BINDIR` under its final name, signed there by `sign.sh`, and renamed
into place. The rename is atomic, and the codesign identifier, which TCC
grants depend on, stays `apple-tasks` / `apple-tasks-private`.

Existing installs whose plist still points into `cli/.build/release` need one
`make install-agent` (and `make install-digest`) to switch over. To exercise
the targets without touching the live job, override every destination:

```bash
make install-agent BINDIR=/tmp/x/bin LAUNCH_AGENTS=/tmp/x/LaunchAgents \
  CONFIG_DIR=/tmp/x/config LAUNCHCTL=true
```
