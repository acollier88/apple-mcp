# apple-tasks-server

Tailscale-facing HTTP wrapper around the `apple-tasks` CLI. No EventKit in
this process — every mutation is `exec` of the CLI (same rule as AgentTasks).

## Run

The binary is **not** in the repo root. Build and put it on PATH the same way
as `apple-tasks`:

```bash
cd ~/apple-mcp
make install-server          # ~/.local/bin/apple-tasks-server
export APPLE_TASKS_SERVE_TOKEN="$(openssl rand -hex 32)"
apple-tasks-server           # default: Tailscale IPv4 or 127.0.0.1:8745
```

Without install, run the built binary directly:

```bash
./server/.build/release/apple-tasks-server
```

Or write `~/.config/apple-tasks/serve.json`:

```json
{ "token": "…", "port": 8745, "bind": "tailscale" }
```

`bind` is `tailscale` (default: `tailscale ip -4`, else 127.0.0.1) or
`loopback`. `--unsafe-lan-bind` is required for `0.0.0.0`.

## Routes

| Method | Path | CLI |
|--------|------|-----|
| GET | `/v1/health` | — |
| GET | `/v1/dispatches?status=&limit=` | `dispatches` |
| GET | `/v1/log?limit=&since=&task=&caller=` | `log` |
| POST | `/v1/dispatch` `{dryRun,agent,list}` | `dispatch` / `--dry-run` |
| GET | `/v1/runs/{id}/log` | file under `~/.config/apple-tasks/runs/` |
| POST | `/v1/triage` `{apply,list}` | `triage` / `--apply` |

All routes except `/v1/health` require `Authorization: Bearer <token>`.
There is no dispatch-cancel route.
