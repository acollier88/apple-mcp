# UX & Architectural Polish Plan

This document outlines design and architectural improvements to elevate **AgentTasks** into a seamless, robust, and premium macOS tool for background agent orchestration.

---

## 1. Unified macOS Menu Bar & XPC Daemon (Taming the TCC Nightmare)

### Context & Friction
macOS Transparency, Consent, and Control (TCC) permissions (Reminders, Calendar, Location, Mail, Contacts) are bound to the host process. If you run the CLI in Terminal, it prompts once; if the MCP server runs it, it prompts again; if a launchd agent runs it, it prompts a third time. This creates constant permission friction and security alerts.

### Proposed Polish
Build a persistent SwiftUI menu bar app that runs a local background XPC daemon.
* **Unified Permission Holder**: The companion app requests all macOS TCC permissions once and performs all EventKit, Contacts, and Location lookups on behalf of the CLI or MCP server via Inter-Process Communication (IPC).
* **Visual Status Dashboard**: A dropdown panel in the menu bar that shows:
  * Running agents with visual progress bars.
  * Real-time scrolling stdout/stderr logs for active runs.
  * A toggle to quickly pause the dispatcher (e.g., "Pause for 2 hours", "Presentation Mode", or "Suspend on Battery").

---

## 2. Apple-Native Push Notifications & Live Activities (HITL Upgraded)

### Context & Friction
Human-in-the-loop (HITL) approvals currently rely on `ntfy.sh`. While functional, it requires sending tokens to an external server, configuring unguessable URL topics, and lacks visual integration with the Apple Watch and iPhone Lock Screen.

### Proposed Polish
Deploy a companion iOS/watchOS app that integrates with **Live Activities** and Apple Push Notification service (APNS).
* **Lock Screen Workflows**: When a running agent requests approval (e.g., `approve request` for a git push, database migration, or email reply), it spawns a Live Activity on the iPhone and Watch.
* **Native Security Actions**: The Lock Screen widget displays the agent's proposed action, relevant diffs/summaries, and native `[Approve]` / `[Deny]` buttons. Approvals are securely synchronized back to the Mac using Apple's local Bonjour networking or iCloud Key-Value Store.

---

## 3. Sandboxed Virtualization (Zero-Risk Unattended Runs)

### Context & Friction
Running agents natively on your host machine with write access (`acceptEdits`) presents security risks. A bug, a hallucinated clean-up script, or an unverified package installation could compromise system files or leak private user data.

### Proposed Polish
Integrate the agent dispatcher with Apple's native **Virtualization.framework** or lightweight Docker containers.
* **Ephemeral Workspaces**: When the dispatcher claims an `[auto]` task, it spins up an isolated virtual machine or container pre-loaded with a clone of the target worktree.
* **Isolated Execution**: The agent performs the coding, compilation, and testing completely within this sandbox.
* **Safe Merge Path**: On success, the container exports only a clean git patch/diff back to the host machine for review, preventing arbitrary execution on the host system.

---

## 4. Interactive Session Hijacking (Virtual Console Intervention)

### Context & Friction
If a dispatched agent runs into a minor compile error, a missing dependency, or a prompt it doesn't know how to resolve, it fails and exits, discarding its context and wasted tokens.

### Proposed Polish
Implement a "Request Intervention" state within [Dispatch.swift](file:///Users/andrewcollier/Code/apple-mcp/Sources/AppleTasks/Dispatch.swift).
* **Paused State**: When an agent hits a retry limit, gets stuck on a failed test, or prompts for input, it pauses its process and triggers an approval-style notification.
* **Virtual Console**: Tapping the notification opens a terminal sheet in the menu bar app, exposing the running shell. The user can type a command, fix the typo, or input the missing value, then click "Resume" to hand control back to the agent.

---

## 5. Multi-Mac Cloud Coordination (Smart Claim Protocol)

### Context & Friction
The database `apple-tasks.db` is local to the machine, but Reminders sync via iCloud. If a user runs dispatchers on multiple machines (e.g., a Mac Studio and a MacBook Pro), it results in race conditions and duplicate agent runs.

### Proposed Polish
Implement a lightweight distributed lock system directly on top of iCloud Drive.
* **Cloud Locks**: When an agent claims a task, it writes an encrypted lock record containing the host's UUID and timestamp to a hidden folder in iCloud Drive (`~/Library/Mobile Documents/...`).
* **Conflict Resolution**: Other hosts watch this folder and yield execution. If the primary host goes offline, secondary hosts can gracefully take over or alert the user.
