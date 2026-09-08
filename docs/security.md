# Security — threat model and publish checklist

Single-user, own Mac. **Dispatched agents are the adversary of record.**
They inherit the user's ambient authority (env, home directory, login
Keychain, the host process's TCC). A prompt-injected agent is
indistinguishable from a malicious one. This doc is grounded in the code
as of P7 step 4; Keychain storage (`Secrets.swift`, `doctor.secrets`) is
**planned, not built**.

## 1. Scope and trust model

**Assets.** Reminders (EventKit + native tags via `apple-tasks-private`);
API keys in `llm.json` / `agents.json` `env` / `launchd.env`; ntfy topic
and `approvalsReplyTopic` (`notify.json`); Gmail `credentials.json` +
`token.json`; Find My `findmy/account.json`; `serve.json` token; the
ledger `apple-tasks.db` (`Audit.swift`); git worktrees under
`~/.config/apple-tasks/worktrees/`; run logs and `.prompt` files under
`runs/`.

**Principals.** The user; launchd (`tools/launchd/run-with-env.sh`); the
dispatcher (`Dispatch.plan` / `Dispatch.execute`); dispatched agents;
the MCP host (`mcp/src/lib.ts` sets `APPLE_TASKS_CALLER=mcp`);
`apple-tasks-server` (iOS bridge).

**Helper trust.** `cli/Sources/private-helper/apple-tasks-private.m`
dlopens private ReminderKit and speaks JSON on stdin. It runs with the
user's Reminders access (same TCC as the CLI). No sockets, no
`NSURLSession` — local XPC to remindd only (`NativeTags` in
`Automation.swift`). A compromised helper can rewrite tags, subtasks,
sections, and attachments; it cannot phone home by itself.

**Central assumption.** `Dispatch.execute` spawns `/usr/bin/env` with
`ProcessInfo.processInfo.environment` plus lane `env`
(`Execute.swift`), `PATH` rewritten by `Dispatch.agentSearchPath`, and
`APPLE_TASKS_CALLER=agent:<tag>`. `worktree: true` isolates the *git
checkout* (`Plan.swift` `git worktree add`). It does **not** isolate
env inheritance, `$HOME`, or Keychain. Example lanes disable the
agent's own sandbox (`examples/agents.json`: cursor `--sandbox
disabled`).

## 2. Prompt-injection surface

`Dispatch.plan` renders `agent.promptTemplate` (default
`AgentsConfig.defaultPromptTemplate`) with `{id}`, `{list}`, `{title}`,
`{notes}`, `{claimTag}`. Delivery is `promptVia`: `argv` (default —
visible in `ps` and stored in the ledger `command` column via
`claimDispatch`), `stdin` (piped after spawn), or `file`
(`runs/<id>.prompt`). See `Dispatch.renderArgv`.

| Source | Lands in | Mitigations today | Gaps |
|---|---|---|---|
| Siri / watch title | `{title}` in `plan` | Lane tag must match `agents.json` or `[auto]` (`Plan.swift`); `requireAutoTag` default true | Title is unsanitized attacker text |
| Task notes | `{notes}` (full, or `(none)`) | `promptVia` `stdin`/`file` keeps it off argv (`Config.swift` `PromptVia`) | Default is still `argv`; no quoting/delimiters |
| Attachments | Extra prompt lines: `kind` + `fileURL` or `url` (`NativeTags.attachments`, first 10) | Paths only, not file bytes | Agent with FDA can read those paths |
| Reminder URL | `{url}` is **not** in the default template. `[research]` appends `URL to research:` (`Plan.swift`) | Research prompt says "do not code" | Other tasks' URL is fingerprint-only (`TaskFingerprint.of`) |
| Note-triage | `Triage.notesPrompt` embeds note `name`+`body`; applied tasks get notes `from note: <name>` | Classifier lanes excluded from routing (`classifierTags`); `Tags.validate` on tags; list must be a plan list | `Triage.swift` always argv-substitutes `{prompt}` — ignores `promptVia` |
| Inbox triage | `Triage.prompt` embeds title + **first 300 chars of notes** | Same routing allow-list; `--agent local` stays on-device (`LocalClassifier`) | Classifier is itself an LLM over untrusted inbox text |
| Mail rule → task | `tools/mail-rule-capture.applescript` writes notes `From` / `Subject` / `Message-ID`, tag `mail` | `[mail]` prompt forbids send; `mail draft` never sends (`Mail.swift`) | Subject/From are attacker-controlled and become `{notes}` |
| `mail_scan` / `gmail_scan` → triage → task | Scan emits headers/snippet; an agent `task_create`s. `gmail_show` can pull a body | Gmail scope `gmail.readonly` (`GmailAuth.scope`); `gmail login` refuses `APPLE_TASKS_CALLER=mcp` | Body can be copied into notes by the creating agent |
| `web_fetch` / `watch_scan` | `WebGet.request` → watch items (title/url/summary) → agent-created `[read]` tasks | Scheme `http`/`https`; `HostPolicy.refusal` blocks RFC1918 / loopback / link-local / `0.0.0.0/8` / CGNAT `100.64/10` / IPv6 `::1` `fc00::/7` `fe80::/10` `::` / `localhost` `.localhost` `.local` `.internal` (literal host; **no DNS**). `WebGet` session delegate re-checks redirects (cap 5). `APPLE_TASKS_ALLOW_PRIVATE_URLS=1` skips | DNS-rebinding out of scope |

**Recursion.** MCP `dispatch_run` returns fail when
`APPLE_TASKS_CALLER` starts with `agent:` (`mcp/src/tools/dispatch.ts`).
CLI `Dispatch.run` uses `Dispatch.recursionRefusal` — live dispatch
throws; `--dry-run` and `--reap-only` stay allowed.

**Not isolated.** Inherited env (including `launchd.env` via
`run-with-env.sh` `set -a`); the whole home directory; login Keychain;
TCC of the dispatcher / MCP host. `maxConcurrent` and per-lane
`maxConcurrent` cap parallelism, not authority. `autoPoolExcluded`
(`triage`, `local`, `doctor`, `heal`) only affects `[auto]` routing.

## 3. Secrets inventory

Resolution **today** is per-consumer (no Keychain). P7 planned order:
**env → keychain → plaintext → error**. Modes below are this Mac's
`~/.config/apple-tasks/` (`ls`/`stat`); `doctor` does not enforce them.

| Secret | File | Mode today | Consumer | Planned P7 source | Notes |
|---|---|---|---|---|---|
| `llm.apiKey` | `llm.json` | file absent here | `LlmCommand.run`: `apiKeyEnv` else `apiKey` | env → keychain → plaintext | Prefer `apiKeyEnv`; comment says chmod 600 if inlined |
| `notify.topic` | `notify.json` | file absent here | `Notifier.push`, `ApprovalTopics.resolve` | same | Topic **is** the auth secret (public relay) |
| `notify.approvalsReplyTopic` | `notify.json` | — | `ApprovalTopics.resolve` | same | Defaults to `<topic>-approvals` |
| `serve.token` | `serve.json` | `600` | `AppleTasksServerMain`: `APPLE_TASKS_SERVE_TOKEN` else file | env already first; then keychain then file | Required; empty token exits 2 |
| Gmail `client_secret` | `gmail/credentials.json` | **not chmod'd in code** | `GmailAuth.loadClient` | env → keychain → plaintext | Dir absent on this Mac; matches review §2.7 |
| Gmail refresh blob | `gmail/token.json` | `600` on `GmailAuth.save` | `GmailAuth.accessToken` (rotation at the save site) | Keychain item `gmail.token`, then delete file | |
| Lane `env` values | `agents.json` | `644` | `Dispatch.execute` overlay | stay in file; MCP redacts display | Wholesale API keys |
| Launchd extras | `launchd.env` | `644` | `run-with-env.sh` `set -a` / `source` | stays; `doctor.secrets` will flag `KEY=` | Wrapper comments cite `CURSOR_API_KEY`, `ANTHROPIC_API_KEY`. This Mac's file is comments only |
| Find My session | `findmy/account.json` | `600` (`chmod` in `findmy-sidecar.py`) | sidecar `load_account` | not in P7 list | §2.7 asset; `ani_libs.bin` is `644` |
| Ledger / audit | `apple-tasks.db` (+ WAL) | `644` | `AuditDB` | — | Caller, command (may include argv prompt), approvals |
| Run / prompt logs | `runs/<id>.log`, `.prompt` | `600` (`RunLogs.create` / `writePrivate` + `setAttributes`) | `Dispatch.execute`, `plan` | — | Agent stdout may echo secrets |

Config dir itself is `755`, not `700`. `runs/` is created `700`
(`RunLogs.ensureDirectory` in `Plan.swift`). Extra file on this Mac:
`hermes-api-server.key` (`600`) — not referenced by this repo.

**MCP display mitigation.** `redactAgentsConfig` in `mcp/src/resources.ts`
(`apple-tasks://config/agents`) replaces every value under an `env`
object and any **string** whose key matches
`/(key|token|secret|password|credential)/i`. Limits: regex on **key
names** only (`topic` is not redacted); does not cover `llm.json`,
`notify.json`, `serve.json`, recipes, or run logs
(`apple-tasks://runs/{id}` is raw tail).

## 4. Network exposure

**ntfy.** Default server `https://ntfy.sh` (`Notify.swift`,
`Approvals.swift`). Whoever knows the topic can read pushes and, on the
reply topic, POST `approve <token>` / `deny <token>`. Tokens are
`UUID` prefix **8 hex chars** (`ApproveRequest`).

Topic entropy: **≥ 24 random characters**. Example (no `/+=`):

```bash
openssl rand -base64 24 | tr -d '/+='
```

Put that in `notify.json` `ntfy.topic` (and a second value in
`approvalsReplyTopic` — do not rely on the `<topic>-approvals` suffix).
There is no `examples/notify.json` yet; this rule lives here until one
exists.

**`apple-tasks-server`.** Token from `APPLE_TASKS_SERVE_TOKEN` or
`serve.json`. Bind: `tailscale` (Tailscale IPv4, else `127.0.0.1`) or
`loopback`; `0.0.0.0` / `::` / `*` refused without `--unsafe-lan-bind`
(`BindResolver.host`). Default port `8745`. Limits (`HTTPLimits`):
16 KiB headers, 1 MiB body, 10 s read timeout, 4 concurrent CLI slots,
run-log tail 256 KiB default / 4 MiB max. `/v1/health` is
**unauthenticated**; every other route needs `Authorization: Bearer`
(`constantTimeEqual`, empty token never matches). Routes exec the CLI
or read `runs/<id>.log` (`RouteArgs` / `ServeHTTP.readRunLog`).

**Gmail.** Scope `https://www.googleapis.com/auth/gmail.readonly`. No
send path in `Gmail.swift`. Loopback OAuth redirect on `127.0.0.1`.

**SSRF.** `WebGet.request` applies `HostPolicy.refusal` before the
fetch (RFC1918, loopback, link-local, `0.0.0.0/8`, CGNAT, `.local` /
`.internal`, IPv6 ULA / link-local / `::` / `::1`). Redirects are
re-checked and capped at 5. Literal host only — no DNS (rebinding out
of scope). Escape hatch: `APPLE_TASKS_ALLOW_PRIVATE_URLS=1` (LAN
watches). Watch URLs come from `watches.json` (user-written);
`web_fetch` takes an agent-supplied URL.

## 5. Operational controls that exist

| Control | What it does | Limit |
|---|---|---|
| Approvals | `approval_request` / `approval_check` / `approval_list`. **No MCP tool answers** (`mcp/src/tools/approvals.ts`). First answer wins; `approve answer` is CLI/human | Agents can still shell `apple-tasks approve answer`. Knowing the reply topic is enough to answer remotely. Prompt templates *ask* for approval; nothing in the CLI enforces it |
| `claimGuard` | `"running"` (default): any `[dispatched…]` blocks. `"modified"`: also skip if fingerprint matches last `open-claimed` success (`Dispatch.unchangedSinceSuccess`) | Does not constrain a live agent |
| `dispatch-cancel` | SIGTERM/KILL tree (`AgentProcess`), row `cancelled`, shed own claim, no `[failed]` (`DispatchCancel`) | Human / MCP / HTTP; not automatic |
| Run logs | stdout/stderr (Cursor NDJSON filtered) + argv header | New files `600` in a `700` `runs/` (`RunLogs`); older files stay `644` until re-chmod'd; served over MCP and HTTP; may contain secrets |
| Audit DB | Every mutation + `APPLE_TASKS_CALLER` (`AuditDB.caller`) | `644`; `argv` prompt can land in `command` |
| `doctor.deployment` | launchd binary vs last `cli/` commit, dirty tree (`Doctor.deploymentStatus`) | No secret-source or mode audit yet |
| Lane caps / gates | `maxConcurrent`, `conditions` (location, power, load, quiet hours, idle, blocking apps) | Availability, not sandboxing |
| Pause | `dispatch-pause` stops new claims; reap/GC still run | Does not kill in-flight agents |

## 6. Publish checklist

Before making the repo public or sharing the MCP config:

1. History grep (all branches, patches):

   ```bash
   git log -p --all | grep -inE 'sk-[a-z0-9]{8,}|ghp_|xox[bp]-|AIza|-----BEGIN'
   ```

2. Review `examples/*.json` — starter lanes only; no real keys, topics, or
   workdir paths that leak private layout you care about.
3. Delete local `agents.json.bak-*` (this Mac has `agents.json.bak-p3`)
   before any copy/screenshot. Same for `~/.config/apple-tasks/` — never
   commit it (README already says so).
4. Treat `~/.config/apple-tasks/runs/` and `logs/` as secret-bearing
   (agent stdout; launchd captures CLI JSON). New run logs are `600`;
   existing ones and `logs/` are `644` — `chmod 700 ~/.config/apple-tasks/runs
   && chmod 600 ~/.config/apple-tasks/runs/* ~/.config/apple-tasks/logs/*` once.
5. Re-read docs screenshots and `docs/review-*.md` for pasted topics/keys.
6. Confirm ntfy topics meet the 24-char rule; rotate if they were
   short or derived from a username.
7. After P7 steps 1–3: rerun `apple-tasks doctor` and expect
   `plaintext` warnings for anything still in files.

## 7. Open items

- **P7 step 1** — `Secrets.swift` over Security.framework (service
  `apple-tasks`, `kSecAttrAccessibleAfterFirstUnlock`, login keychain so
  launchd can read after login). `secret set` from `--stdin` / prompt,
  never argv. **Not started** (no `Secrets.swift`).
- **P7 step 2** — consumers resolve env → keychain → plaintext for
  `llm.apiKey`, `notify.topic`, `notify.approvalsReplyTopic`,
  `serve.token`, Gmail `client_secret` + `gmail.token`. Today: env-or-file
  only (`Llm.swift`, `Notify.swift`, `main.swift`, `Gmail.swift`).
- **P7 step 3** — `doctor.secrets`: per-secret `source`, modes not `600`,
  `credentials.json` chmod fix-it. `Doctor` today audits TCC, helper,
  FDA, `agents.json` parse, launchd, Hermes/HA presence, `deployment`.
- **Roadmap #16** — run `/security-review` *after* P7; land findings
  here. This file is the checklist, not that review.
