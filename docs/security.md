# Security — threat model and publish checklist

Single-user, own Mac. **Dispatched agents are the adversary of record.**
They inherit the user's ambient authority (env, home directory, login
Keychain, the host process's TCC). A prompt-injected agent is
indistinguishable from a malicious one. This doc is grounded in the code
as of P7 step 4; Keychain storage (`Secrets.swift`, `doctor.secrets`) is
**built**. Consumers resolve env → keychain → plaintext; `doctor.secrets`
reports the source. Roadmap #16 (post-P7 `/security-review`) is still open.

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
`AgentEnv.build` over `ProcessInfo.processInfo.environment`
(`AgentEnv.swift`): filtered by `envMode` (lane, else top-level, else
`inherit`) and `envPassthrough`, then lane `env`,
`APPLE_TASKS_CALLER=agent:<tag>`, and `PATH` rewritten by
`Dispatch.agentSearchPath`. `Triage.runAgent` (triage and suggest seats)
uses the same filter without the caller/PATH steps. `inherit` is the
default, so a config that sets nothing still hands agents the whole
dispatcher env, `launchd.env` included. `scrubSecrets` drops variables by
**name** pattern only; `allowlist` keeps a small base set. Neither stops
an agent reading files: `worktree: true` isolates the *git checkout*
(`Plan.swift` `git worktree add`), not `$HOME` or Keychain. Example lanes
disable the agent's own sandbox (`examples/agents.json`: cursor
`--sandbox disabled`).

## 2. Prompt-injection surface

`Dispatch.plan` renders `agent.promptTemplate` (default
`AgentsConfig.defaultPromptTemplate`) with `{id}`, `{list}`, `{title}`,
`{notes}`, `{claimTag}` in one pass (`PromptTemplate.render`; values are
never re-scanned). The default template puts title and notes inside
`<<<BEGIN/END UNTRUSTED TASK TITLE|NOTES>>>` blocks, says their contents
are data, and forbids reading credential/keychain/token/SSH/dotenv files.
`PromptTemplate.neutralise` breaks `<<<` / `>>>` runs in title, notes,
list, attachment paths and the research URL, so task text cannot close a
block early. Custom templates without the markers render as before.
Delivery is `promptVia`: `argv` (default — visible in `ps`), `stdin`
(piped after spawn), or `file`. Every mode writes `runs/<id>.prompt`
(`600`); the ledger `command` column and run-log header carry
`Dispatch.ledgerCommand` (prompt replaced by `<prompt omitted>`). See
`Dispatch.renderArgv`.

Delimiters are framing for the model, not enforcement: a model can still
follow instructions inside a block.

| Source | Lands in | Mitigations today | Gaps |
|---|---|---|---|
| Siri / watch title | `{title}` in `plan` | Lane tag must match `agents.json` or `[auto]` (`Plan.swift`); `requireAutoTag` default true; untrusted block in the default template; marker runs neutralised; single-pass render | Model may still obey it; custom templates without markers get no framing |
| Task notes | `{notes}` (full, or `(none)`) | Same block/neutralise/single-pass; `promptVia` `stdin`/`file` keeps it off argv; never stored in the ledger | Default `promptVia` is still `argv` (visible in `ps` for the run's lifetime) |
| Attachments | Extra prompt lines: `kind` + `fileURL` or `url` (`NativeTags.attachments`, first 10), inside an `UNTRUSTED ATTACHMENTS` block | Paths only, not file bytes; neutralised | Agent with FDA can read those paths |
| Reminder URL | `{url}` is **not** in the default template. `[research]` appends `URL to research:` (`Plan.swift`), neutralised; the raw title is no longer repeated outside the block | Research prompt says "do not code" and to treat fetched text as data | Other tasks' URL is fingerprint-only (`TaskFingerprint.of`) |
| Note-triage | `Triage.notesPrompt` embeds note `name`+`body`; applied tasks get notes `from note: <name>` | Classifier lanes excluded from routing (`classifierTags`); `Tags.validate` on tags; list must be a plan list | `Triage.swift` always argv-substitutes `{prompt}` — ignores `promptVia` |
| Inbox triage | `Triage.prompt` embeds title + **first 300 chars of notes** | Same routing allow-list; `--agent local` stays on-device (`LocalClassifier`) | Classifier is itself an LLM over untrusted inbox text |
| Mail rule → task | `tools/mail-rule-capture.applescript` writes notes `From` / `Subject` / `Message-ID`, tag `mail` | `[mail]` prompt forbids send; `mail draft` never sends (`Mail.swift`) | Subject/From are attacker-controlled and become `{notes}` |
| `mail_scan` / `gmail_scan` → triage → task | Scan emits headers/snippet; an agent `task_create`s. `gmail_show` can pull a body | Gmail scope `gmail.readonly` (`GmailAuth.scope`); `gmail login` refuses `APPLE_TASKS_CALLER=mcp` | Body can be copied into notes by the creating agent |
| `web_fetch` / `watch_scan` | `WebGet.request` → watch items (title/url/summary) → agent-created `[read]` tasks | Scheme `http`/`https`; `HostPolicy` blocks RFC1918 / loopback / link-local / `0.0.0.0/8` / CGNAT `100.64/10` / multicast / `240/4` / IPv6 `::1` `fc00::/7` `fe80::/10` `fec0::/10` `ff00::/8` `::`, IPv4 embedded in IPv6 (mapped, translated, compatible, NAT64, 6to4, Teredo) / `localhost` `.localhost` `.local` `.internal`. Hostnames are **resolved** (every A/AAAA must pass; unresolvable is refused) before the request and on every redirect hop (cap 5); the address actually connected to is vetted from URLSession metrics before the body is returned. `APPLE_TASKS_ALLOW_PRIVATE_URLS=1` skips | DNS-rebinding window narrowed, not closed — see §4 SSRF |

**Recursion.** MCP `dispatch_run` returns fail when
`APPLE_TASKS_CALLER` starts with `agent:` (`mcp/src/tools/dispatch.ts`).
CLI `Dispatch.run` uses `Dispatch.recursionRefusal` — live dispatch
throws; `--dry-run` and `--reap-only` stay allowed.

**Argv injection.** MCP tools and `RouteArgs` build CLI argv from
agent/HTTP strings. Free-text positionals go behind `--`
(`positionals()` in `mcp/src/lib.ts`), and option values use the
attached `--flag=value` form (`opt()`, `RouteArgs.option`) because
swift-argument-parser rejects `--flag -x` but accepts `--flag=-x`; an
empty value keeps the split form (`--flag=` is "missing value").
`ArgvParsingTests` pins that parser behaviour.

**Not isolated.** Inherited env (including `launchd.env` via
`run-with-env.sh` `set -a`) unless a lane sets `envMode`, and even then
only by name; the whole home directory; login Keychain; TCC of the
dispatcher / MCP host. `maxConcurrent` and per-lane
`maxConcurrent` cap parallelism, not authority. `autoPoolExcluded`
(`triage`, `local`, `doctor`, `heal`) only affects `[auto]` routing.

## 3. Secrets inventory

Resolution **today** is per-consumer: **env → keychain → plaintext →
missing**. `Secrets.resolve` (`Secrets.swift`) is the shared helper;
`doctor.secrets` (`Doctor.secretsStatus`) reports `source` and file modes.
`--fix-modes` chmods group/world-readable known files to `600`. Modes
below are this Mac's `~/.config/apple-tasks/` (`ls`/`stat`).

| Secret | File | Mode today | Consumer | Source now | Notes |
|---|---|---|---|---|---|
| `llm.<profile>.apiKey` | `llm.json` | file absent here | `LlmCommand.run`: `apiKeyEnv` → `apiKeyKeychain` / `llm.<profile>.apiKey` → `apiKey` | env → keychain → plaintext | Prefer `apiKeyEnv`; comment says chmod 600 if inlined |
| `ntfy.topic` | `notify.json` | file absent here | `NotifyConfig.resolveTopic` (`Notifier.push`, `ApprovalTopics.resolve`) | env `APPLE_TASKS_NTFY_TOPIC` → keychain `ntfy.topic` → file | Topic **is** the auth secret (public relay) |
| `ntfy.approvalsReplyTopic` | `notify.json` | — | `NotifyConfig.resolveApprovalsReplyTopic` | env `APPLE_TASKS_NTFY_APPROVALS_TOPIC` → keychain → file → `<topic>-approvals` (inherits topic source) | Keep as unguessable as the main topic |
| `serve.token` | `serve.json` | `600` | `AppleTasksServerMain`: `APPLE_TASKS_SERVE_TOKEN` → keychain `serve.token` → file | env → keychain → file | Required; empty token exits 2 |
| Gmail `client_secret` | `gmail/credentials.json` | **not chmod'd in code** | `GmailAuth.loadClient` / `Client.resolvedClientSecret` | env `APPLE_TASKS_GMAIL_CLIENT_SECRET` → keychain `gmail.clientSecret` → file | Dir absent on this Mac; matches review §2.7 |
| Gmail refresh blob | `gmail/token.json` | `600` on `GmailAuth.save` | `GmailAuth.loadToken` / `save` (rotation writes Keychain when `gmail.token` already exists) | keychain `gmail.token` → file; `GmailAuth.tokenSource` | `secret migrate --apply` deletes the file |
| Lane `env` values | `agents.json` | `644` | `Dispatch.execute` overlay | stay in file; `doctor` flags `agents.json:env`; MCP redacts display | Wholesale API keys |
| Launchd extras | `launchd.env` | `644` | `run-with-env.sh` `set -a` / `source` | stays; `doctor.secrets` flags each `export NAME=value` as `launchd.env:NAME`. Agents inherit these unless the lane's `envMode` drops them | Wrapper comments cite `CURSOR_API_KEY`, `ANTHROPIC_API_KEY`. This Mac's file is comments only |
| Find My session | `findmy/account.json` | `600` (`chmod` in `findmy-sidecar.py`) | sidecar `load_account` | not in P7 list | §2.7 asset; `ani_libs.bin` is `644` |
| Ledger / audit | `apple-tasks.db` (+ WAL) | `644` | `AuditDB` | — | Caller, command (prompt replaced by `<prompt omitted>` for rows written since #27; older rows may still hold argv prompts), approvals |
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

**SSRF.** `web_fetch` takes an agent-supplied URL; watch URLs come from
`watches.json` (user-written). `WebGet.request` (`Watches.swift`)
applies three layers from `HostPolicy.swift`:

1. *Literal host* — `HostPolicy.refusal(for:)`: IP literals (including
   `inet_aton` shorthand/octal/hex and IPv6 forms that embed an IPv4)
   and reserved names (`localhost`, `.local`, `.internal`, trailing dot
   ignored) against the ranges in §2.
2. *Resolve and check* — `HostPolicy.refusal(for:resolve:)`:
   `getaddrinfo` (A + AAAA); refuse if **any** answer is blocked, or the
   name does not resolve. Runs before the request and again in the
   per-request delegate on every redirect hop (cap 5, http/https only).
3. *Connected address* — after the load, `WebGetTaskDelegate` checks
   `URLSessionTaskTransactionMetrics.remoteAddress` for every network
   transaction (one per hop) and throws instead of returning the body if
   any is blocked. Missing metrics or a missing address fail closed. The
   session is ephemeral with no cache, so every load is a network load.

**Why not pin the vetted IP.** The clean fix — connect to the address
we checked while keeping `Host`, SNI and certificate validation for the
original name — is not available through URLSession: an IP-literal URL
sends no SNI (most CDN/virtual-hosted HTTPS then fails), and `Host` is
a header URLSession reserves. Faking it in a trust-evaluation delegate
would mean overriding TLS validation, which we will not ship.
Network.framework (`NWConnection` to the IP with
`sec_protocol_options_set_tls_server_name`) can pin correctly, but has
no HTTP client; it would mean hand-writing HTTP/1.1 (chunked bodies,
redirects, content-encoding). Not done; possible future work.

**Remaining rebinding window.** A hostile DNS server with TTL 0 can
answer our `getaddrinfo` with a public address and URLSession's own
lookup a moment later with a private one. Layer 3 catches that, but
only **after** the request was sent: the private service receives one
plain `GET` (our User-Agent, no cookies, no body, no agent-chosen
headers). The response body, title and status are withheld; the error
names the address, which the attacker chose anyway. So this is now a
*blind* SSRF window for idempotent-in-theory GETs, not a read. Also
not covered: transactions over a system HTTP proxy are not checked in
layer 3 (`remoteAddress` is the proxy's, and the proxy resolves the
origin), and layer 2 still runs against local DNS.

Escape hatch: `APPLE_TASKS_ALLOW_PRIVATE_URLS=1` (LAN watches) skips
all three layers.

## 5. Operational controls that exist

| Control | What it does | Limit |
|---|---|---|
| Approvals | `approval_request` / `approval_check` / `approval_list`. **No MCP tool answers** (`mcp/src/tools/approvals.ts`). First answer wins; `approve answer` is CLI/human and refuses `APPLE_TASKS_CALLER=agent:*` (`CallerGuard.approvalAnswerRefusal`, audited as `refused`) | Caller guard is a speed bump (see below). Knowing the reply topic is enough to answer remotely. Prompt templates *ask* for approval; nothing in the CLI enforces it |
| Secret caller guard | `secret get` (without `--quiet`), `secret set`, `secret rm`, `secret migrate --apply` refuse `APPLE_TASKS_CALLER=agent:*` or `mcp` with a non-zero exit and an audit row (`CallerGuard.secretRefusal`). `--quiet` presence checks and dry-run `migrate` stay open. No TTY rule: `$(apple-tasks secret get x)` pipes stdout, and an agent can allocate a pty anyway | **Speed bump, not a boundary**: an agent running as the same user can unset or overwrite `APPLE_TASKS_CALLER`, or read the login Keychain directly (`security find-generic-password`) |
| `claimGuard` | `"modified"` (default since 2026-09-16): any `[dispatched…]` blocks, plus skip if fingerprint matches last `open-claimed` success (`Dispatch.unchangedSinceSuccess`). `"running"`: tag check only | Does not constrain a live agent |
| `dispatch-cancel` | SIGTERM/KILL tree (`AgentProcess`), row `cancelled`, shed own claim, no `[failed]` (`DispatchCancel`) | Human / MCP / HTTP; not automatic |
| Run logs | stdout/stderr (Cursor NDJSON filtered) + header (argv with `<prompt omitted>`, env mode and dropped variable names) | New files `600` in a `700` `runs/` (`RunLogs`); older files stay `644` until re-chmod'd; served over MCP and HTTP; may contain secrets |
| Agent env filter | `envMode` `inherit` (default) / `scrubSecrets` / `allowlist` + `envPassthrough` (`AgentEnv`) | Opt-in; name-based; does not cover files, Keychain or TCC |
| Credential-path flag | Phase C `CredentialScan.scanLog` over the run log (≤ 1 MiB head + tail, header skipped): `.ssh/`, `gh/hosts.yml`, `.aws/credentials`, `.netrc`, `Keychains/`, `security find-*-password`, `launchd.env`, gmail/findmy secret files, `.env` → `cred-paths-in-log=` in trailer, ledger summary, notification, report | Flags only, after the fact; sees only what the agent printed; mentions are not proof of reads |
| Audit DB | Every mutation + `APPLE_TASKS_CALLER` (`AuditDB.caller`) | `644`; dispatch `command` no longer carries the prompt (older rows may) |
| `doctor.deployment` | launchd binary vs last `cli/` commit, dirty tree (`Doctor.deploymentStatus`) | Drift only; not a secret audit |
| `doctor.secrets` | per-secret `source` / file mode (`Doctor.secretsStatus`); info issue `secrets-plaintext` (does not enqueue heals); `--fix-modes` | Does not move values — `secret migrate --apply` does |
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
7. Rerun `apple-tasks doctor` and expect `plaintext` notes (and a
   `secrets-plaintext` info issue) for anything still in files; then
   `apple-tasks secret migrate --apply`.

## 7. Open items

- **P7 step 1 — done.** `Secrets.swift`: service `apple-tasks`, login
  keychain (`KeychainSecretStore`); `Secrets.resolve` / `keychainValue`;
  `secret set|get|rm|list|migrate` (`SecretCommand`) reads values from
  `--stdin` or a no-echo prompt, never argv.
- **P7 step 2 — done.** Consumers resolve env → keychain → plaintext:
  `LlmCommand.run` (`apiKeyEnv` → `apiKeyKeychain` / `Secrets.llmApiKey`
  → `apiKey`); `NotifyConfig.resolveTopic` /
  `resolveApprovalsReplyTopic`; `ApprovalTopics.resolve`;
  `GmailAuth.loadClient` / `resolvedClientSecret`, `loadToken` / `save`
  / `tokenSource`; serve token is the other engineer's `main.swift`.
- **P7 step 3 — done.** `Doctor.secretsStatus` + `DoctorOut.secrets`;
  `--fix-modes`; info issue `secrets-plaintext` (skipped by
  `enqueueHeals` — severity `info`).
- **Roadmap #16** — run `/security-review` *after* P7; land findings
  here. This file is the checklist, not that review. Still open.
