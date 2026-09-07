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

## Methods and callers

### `record(command:taskId:list:detail:result:error:)`

Commands.swift (add/update/complete/uncomplete/delete/lists add/remirror-tags),
Dispatch.swift (dispatch, dispatch-retry, dispatch-reap),
Triage.swift, Suggest.swift (via digest), Notify.swift, Mail.swift,
Events.swift, Digest.swift, Approvals.swift, Gmail.swift, Watches.swift,
GitHubSync.swift.

### Dispatch ledger

| Method | Callers |
|--------|---------|
| `claimDispatch(...)` | Dispatch.swift |
| `finishDispatch(id:status:exitCode:)` | Dispatch.swift |
| `setDispatchPaths(id:runLogPath:worktree:)` | Dispatch.swift |
| `dispatchRows(status:limit:)` | Dispatch.swift (`dispatches` cmd), Digest.swift, Doctor.swift |
| `hasActiveDispatch(taskId:)` | Dispatch.swift |
| `activeDispatchCount(agent:)` | Dispatch.swift |
| `reapStale(before:)` | Dispatch.swift |
| `failedAttempts(taskId:)` | Dispatch.swift |
| `worktreeRows()` | Dispatch.swift |
| `clearWorktree(id:)` | Dispatch.swift |

### State KV

| Method | Callers |
|--------|---------|
| `getState` / `setState` | Automation.swift |

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
