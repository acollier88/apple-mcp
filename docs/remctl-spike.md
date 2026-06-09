# Spike: remctl learnings (2026-06-09)

Source: github.com/viticci/remctl (MIT-style open source, shallow-cloned and
read; ~2.8k lines across the private helper, Swift bridge, and docs).

## Architecture (theirs)

Reads and writes are deliberately split:

- **Reads**: Python reads Reminders' CoreData SQLite directly, read-only
  (`~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite`).
  Exposes everything EventKit hides: tags, subtasks, sections, attachments,
  list colors, recurrence, urgent state. Requires Full Disk Access.
- **Normal writes**: Swift bridge via public EventKit (same as our CLI).
- **Private writes**: a small ObjC helper (`remctl-private.m`, ~1.5k lines)
  that declares private ReminderKit interfaces and writes through Apple's own
  Reminders stack. Gated behind an explicit `--private` flag. **Never writes
  SQLite** — earlier experiments proved direct row inserts can stay local-only
  and never sync to iCloud.

## The key mechanism: native tag writes

The entire native-tag write path is ~6 lines of ObjC against private
ReminderKit:

```objc
// 1. Build an object ID from the CloudKit identifier
NSURL *url = [NSURL URLWithString:
    @"x-apple-reminderkit://REMCDReminder/<CK-IDENTIFIER>"];
id objectID = [REMObjectID objectIDWithURL:url];

// 2. Fetch, mutate via change-item contexts, save
REMStore *store = [REMStore new];
id reminder = [store fetchReminderWithObjectID:objectID error:&err];
REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
REMReminderChangeItem *change = [save updateReminder:reminder];
[[change hashtagContext] addHashtagWithType:1 name:@"claude"];
[save saveSynchronouslyWithError:&err];
```

Compile with:

```bash
clang -fobjc-arc -O -F/System/Library/PrivateFrameworks \
  -framework Foundation -framework AppKit -framework ReminderKit \
  -o remctl-private remctl-private.m
```

**The big win for us**: the `<CK-IDENTIFIER>` in the object URL is the CloudKit
identifier (`ZCKIDENTIFIER` in SQLite) — which is the same value EventKit
exposes as `calendarItemExternalIdentifier`, i.e. the `externalId` field our
CLI already outputs on every task. So we can write native tags with a tiny
ObjC helper and **zero SQLite reads and zero Full Disk Access**:
EventKit (create/find, get externalId) → ReminderKit helper (add tags).

The same `REMReminderChangeItem` context pattern covers everything else:
`subtaskContext` (real subtasks), `attachmentContext` (rich URLs/images),
`flaggedContext`, `urgentAlarmContext`, `dueDateDeltaAlertContext`
(early reminders), section assignment, shared-list assignment.

## Patterns worth copying regardless of private APIs

1. **Explicit opt-in flag for unsupported paths** (`--private`): private-only
   options hard-fail without it, so nothing silently drops metadata. If we add
   a ReminderKit backend, gate it the same way (`--native-tags`).
2. **Verify-after-write**: their agent docs mandate reading the item back
   after private writes; sync isn't guaranteed just because save succeeded.
3. **Bounded JSON-over-stdin helper protocol**: the ObjC helper accepts a
   fixed action set, no arbitrary selectors, no shell. Good containment for a
   private-API surface.
4. **TCC grants are per-host-process**: their `doctor --for-agent` exists
   because Terminal working ≠ the MCP host working. We should add an
   `apple-tasks doctor` that checks Reminders/Calendar/Automation access and
   reports which host process it's running under.
5. **Helper-path env overrides** (`REMCTL_PRIVATE_PATH` etc.) so agents can
   diagnose exactly which binary failed — mirrors our `APPLE_TASKS_BIN`.
6. **Terminal-control-character neutralization** in human output (prompt
   injection / terminal escape hygiene for agent-read content). JSON keeps raw
   values.

## What we'd bring over (proposed, not yet built)

Phase 1 — no private APIs:
- `apple-tasks doctor` (TCC status per capability, binary paths, watermark
  state).

Phase 2 — optional native-tags backend:
- `apple-tasks-private` ObjC helper (~200 lines: hashtag + subtask contexts
  only), built by a `make private` target, never required.
- `add`/`update` gain `--native-tags`: EventKit write first, then helper call
  keyed by `externalId`. `[tag]` prefix remains the default and the fallback.
- Read side stays EventKit + title parsing (tags written natively are
  invisible to EventKit reads — would need SQLite reads + Full Disk Access to
  read them back, which is the main reason to keep [tag] prefixes as the
  source of truth and treat native tags as write-only mirroring for
  Reminders-app UX).

## Risks

- Private framework: any macOS update can rename classes/selectors or change
  sync semantics. remctl's docs confirm this is verified on macOS 26; we are
  on the macOS 27 beta — selectors must be re-verified before building
  Phase 2 (a quick `nm`/runtime respondsToSelector probe in the helper at
  startup would make failures graceful).
- Writing tags natively while parsing tags from titles creates a dual-source
  problem; the write-only-mirror design above avoids divergence.
