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
| POST | `/v1/dispatch` `{dryRun,agent,list,reapOnly}` | `dispatch`. **`dryRun` defaults to true** (omit/`true` → `--dry-run`, 60s). Only the literal `"dryRun": false` is a live run (1800s). `reapOnly: true` → `--reap-only`. |
| GET | `/v1/runs/{id}/log?tail=` | last `tail` bytes of `~/.config/apple-tasks/runs/{id}.log` (default 262144, max 4 MiB) |
| POST | `/v1/triage` `{apply,list,agent,notes}` | `triage` / `--apply` / `--inbox <list>` / `--agent` / `--notes` |
| POST | `/v1/dispatches/{id}/cancel` | `dispatch-cancel {id}` — kills the agent tree, marks the row `cancelled`, sheds the claim tag; no `[failed]`, no retry (30s) |

All routes except `/v1/health` require `Authorization: Bearer <token>`.

## Limits

- Header block larger than 16 KiB → `431`
- Declared `Content-Length` larger than 1 MiB → `413`
- Request not finished within 10s of the first byte → connection closed (`408` when a response can be sent)
- At most 4 concurrent CLI executions; waiting longer than 1s → `503`

## Errors

Every non-2xx JSON body is:

```json
{"error": "<message>", "code": "<snake_case_code>"}
```

Codes: `unauthorized`, `not_found`, `bad_request`, `payload_too_large`, `headers_too_large`, `timeout`, `busy`, `cli_failed`.

When the CLI process fails, the body also includes `"exitCode": <n>` if the exit status is known.
