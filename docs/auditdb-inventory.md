# AuditDB caller inventory

`AuditDB` is a concrete SQLite singleton in
`cli/Sources/AppleTasks/Audit.swift`. There is no `LedgerStore` protocol.
Any future Supabase backend must implement **all** of these call sites or
the dispatcher will silently skip work / lose audit.

## Tables

- `audit` — append-only mutation log
- `dispatches` — run ledger + claim lock
- `state` — KV (watermarks)
- `approvals` — ntfy approval tokens (Mac-side; not Gatehouse)

## Schema versioning

`PRAGMA user_version` drives forward-only migrations in `AuditDB.migrate()`;
`AuditDB.schemaVersion` is the version the code expects. Version 0 is any DB
created before 2026-09-07 (columns were added by error-ignored `ALTER`s on
every open). Each case is idempotent (`addColumnIfMissing`) because v0 DBs
may or may not already carry the ad-hoc columns.

| Version | Adds |
|---|---|
| 1 | `dispatches.run_log_path/worktree/summary` (formalized), `dispatches.pid` (agent process id for reap/cancel), `dispatches.task_modified_at` (P3 re-dispatch guard) |

`AuditDBTests.testMigratesVersionZeroDatabase` builds a v0 DB by hand and
asserts the upgrade keeps rows and is a no-op on reopen.

## Methods and callers

### `record(command:taskId:list:detail:result:error:)`

Commands.swift (add/update/complete/uncomplete/delete/lists add/remirror-tags),
Dispatch.swift (dispatch, dispatch-retry, dispatch-reap, dispatch-cancel, dispatch-discard),
Triage.swift, Suggest.swift (via digest), Notify.swift, Mail.swift,
Events.swift, Digest.swift, Approvals.swift, Gmail.swift, Watches.swift,
GitHubSync.swift.

### Dispatch ledger

`claimDispatch(...) -> ClaimResult` is fail-closed. Cases:

- `.claimed(Int64)` — this dispatcher holds the claim; ledger row id
- `.held` — another dispatcher already has a `running` row for this task
- `.unavailable` — ledger DB is not open (`isAvailable == false`); caller
  must **not** dispatch (never treat a sentinel id as a real claim)

`finishDispatch`, `setDispatchPaths`, `setDispatchPid`, and `clearWorktree`
return `@discardableResult Bool` (`false` when `db == nil`).

`dispatches.status` values: `running` | `succeeded` | `failed` | `timeout` |
`cancelled` | `aborted`. `cancelled` is a human cancel (`dispatch-cancel`);
it is **not** counted by `failedAttempts` (retry/backoff stays
`failed`/`timeout` only) and GC treats its worktree like `failed`/`timeout`
(`keepFailedWorktreeDays`).

| Method | Callers |
|--------|---------|
| `claimDispatch(...) -> ClaimResult` | Dispatch.swift |
| `finishDispatch(id:status:exitCode:) -> Bool` | Dispatch.swift (write-back, dead-pid reap), `dispatch-cancel` |
| `setDispatchPid(id:pid:) -> Bool` | Dispatch.swift (Phase B, immediately after spawn) |
| `setDispatchPaths(id:runLogPath:worktree:) -> Bool` | Dispatch.swift |
| `dispatchRows(status:limit:)` | Dispatch.swift (`dispatches` cmd, dead-pid reap), Digest.swift, Doctor.swift |
| `dispatchRow(id:)` | Dispatch.swift (scratch-dir GC), `dispatch-cancel`, `dispatch-discard` |
| `hasActiveDispatch(taskId:)` | Dispatch.swift |
| `activeDispatchCount(agent:)` | Dispatch.swift |
| `reapStale(before:)` | Dispatch.swift |
| `failedAttempts(taskId:)` | Dispatch.swift (excludes `cancelled`) |
| `worktreeRows()` | Dispatch.swift (`succeeded`/`failed`/`timeout`/`cancelled`) |
| `clearWorktree(id:) -> Bool` | Dispatch.swift, PendingReview.swift (gone worktree), `dispatch-discard` |
| `pendingReviewRows(limit:)` | PendingReview.swift (`dispatches --status pending-review`, Digest) |
| `markReviewed(id:) -> Bool` | PendingReview.swift (merged/gone auto-review), `dispatch-discard` |
| `isAvailable` | Dispatch.swift (one stderr warning per pass) |

### State KV

| Method | Callers |
|--------|---------|
| `getState` / `setState` | Automation.swift, Dispatch.swift (`dispatch.lastReportHash` for `--quiet`) |

### Approvals (ntfy)

| Method | Callers |
|--------|---------|
| `createApproval` | Approvals.swift |
| `approvalRows` | Approvals.swift |
| `answerApproval` (CAS) | Approvals.swift |

### Reads

| Method | Callers |
|--------|---------|
| `auditRows(since:taskId:caller:limit:)` | Dispatch.swift (`log` cmd), Suggest.swift, Digest.swift |

## Future Postgres claim (not v1)

Do **not** rely on `INSERT … WHERE NOT EXISTS` alone under `READ COMMITTED`.
Required:

```sql
CREATE UNIQUE INDEX dispatches_one_active
  ON dispatches (task_id)
  WHERE status IN ('running', 'succeeded');
```

Then `INSERT … ON CONFLICT DO NOTHING` (prefer a security-definer RPC).
Two-connection race test required. Claim failure must fail closed.

Phone must not use a Supabase anon key with broad `SELECT` on these tables.
