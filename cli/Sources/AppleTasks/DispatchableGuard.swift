import Foundation

/// Stops dispatched agents from queueing work for the dispatcher (#66).
///
/// A task is dispatchable when its title carries `[auto]`, or a lane tag
/// while `requireAutoTag` is off (`Dispatch.plan`). When an `agent:*`
/// caller would create such a task through `add` / `add-batch`, the task is
/// not created; it is filed in the proposals inbox (#53) and runs only if
/// the human accepts it. `update` and `sync-github` refuse instead.
///
/// Internal flows that create dispatchable tasks in-process (`doctor
/// --enqueue-heals`, `proposals accept`, `dispatch-retry`) do not pass
/// through these commands and are unaffected; the last two already refuse
/// agent callers (`CallerGuard.reviewRefusal`).
///
/// Like every caller guard this is a speed bump, not a boundary: an agent
/// can unset `APPLE_TASKS_CALLER`. The enforced form is a gatehouse policy
/// on `apple-tasks add` once lanes are sandboxed (#39).
enum DispatchableGuard {
    static let detector = "agent-task"

    struct Context: Equatable {
        var laneNames: Set<String>
        var requireAuto: Bool

        static func live() -> Context {
            guard let config = try? AgentsConfig.load() else {
                return Context(laneNames: [], requireAuto: true)
            }
            return Context(laneNames: Set(config.agents.keys.map { $0.lowercased() }),
                           requireAuto: config.requireAutoTag ?? true)
        }
    }

    /// Lowercased tags on `title` that make the dispatcher pick it up: `auto`
    /// plus any lane tags when `auto` is present, or the lane tags alone when
    /// `requireAutoTag` is off. Empty means the dispatcher ignores the task.
    static func dispatchTags(title: String, context: Context) -> [String] {
        let tags = Tags.parse(title).tags.map { $0.lowercased() }
        let lanes = tags.filter { context.laneNames.contains($0) }
        if tags.contains("auto") { return ["auto"] + lanes.filter { $0 != "auto" } }
        return context.requireAuto ? [] : lanes
    }

    /// The lane an accepted proposal should run on: the named lane, else the
    /// `[auto]` pool.
    static func lane(dispatchTags: [String]) -> String? {
        dispatchTags.first { $0 != "auto" } ?? (dispatchTags.contains("auto") ? "auto" : nil)
    }

    /// Tags a model chose while reading untrusted text (triage). `[auto]` is
    /// the human's call, so it never comes from model output.
    static func modelTags(_ tags: [String]?) -> [String] {
        (tags ?? []).filter { (try? Tags.validate($0)) != nil && $0.lowercased() != "auto" }
    }

    static func shouldPropose(caller: String?, title: String, context: Context) -> Bool {
        CallerGuard.isDispatchedAgent(caller) && !dispatchTags(title: title, context: context).isEmpty
    }

    /// `update` may not add dispatch tags the task did not already have.
    static func updateRefusal(caller: String?, before: String, after: String, context: Context) -> String? {
        guard CallerGuard.isDispatchedAgent(caller), let caller else { return nil }
        let added = Set(dispatchTags(title: after, context: context))
            .subtracting(dispatchTags(title: before, context: context))
        guard !added.isEmpty else { return nil }
        return "update cannot add dispatch tags (\(added.sorted().map { "[\($0)]" }.joined())) "
            + "for dispatched agents (APPLE_TASKS_CALLER=\(caller)); create the task with `add` "
            + "and it will be filed as a proposal for the human"
    }

    static func syncRefusal(caller: String?, tags: [String], context: Context) -> String? {
        guard CallerGuard.isDispatchedAgent(caller), let caller else { return nil }
        let title = Tags.compose(tags: ["github"] + tags, title: "x")
        guard !dispatchTags(title: title, context: context).isEmpty else { return nil }
        return "sync-github cannot tag issues for dispatch when run by a dispatched agent "
            + "(APPLE_TASKS_CALLER=\(caller))"
    }

    struct ProposedOut: Codable, Equatable {
        var status = "proposed"
        var proposalId: Int?
        var fingerprint: String
        var title: String
        var lane: String?
        var message: String
    }

    /// File the would-be task in the proposals inbox. `title` is the composed
    /// title (tags included); the proposal keeps the clean title, and accepting
    /// it re-adds only `[auto]` and the lane.
    static func propose(caller: String, list: String, title: String, notes: String?,
                        context: Context, db: AuditDB = .shared) -> ProposedOut {
        let parsed = Tags.parse(title)
        let lane = lane(dispatchTags: dispatchTags(title: title, context: context))
        var evidence = "requested by: \(caller)\nlist: \(list)\ntags: "
            + parsed.tags.map { "[\($0)]" }.joined()
        if let notes, !notes.isEmpty { evidence += "\nnotes:\n\(notes)" }
        let fp = ProposalsInbox.fingerprint(detector: detector, kind: caller, title: "\(list)\n\(parsed.title)")
        _ = ProposalsInbox.remember(
            detector: detector, kind: caller, title: parsed.title, evidence: evidence,
            lane: lane, fingerprint: fp, db: db)
        let row = db.finding(fingerprint: fp)
        db.record(command: "add", list: list, detail: parsed.title, result: "proposed",
                  error: "dispatchable task from \(caller) filed as proposal \(row.map { String($0.id) } ?? fp)")
        let ref = row.map { String($0.id) } ?? fp
        let message: String
        if row?.state == "dismissed" {
            message = "Not created: the human already dismissed this request (proposal \(ref))."
        } else {
            message = "Not created: tasks a dispatched agent marks for dispatch need the human's approval. "
                + "Filed as proposal \(ref); the human can run `apple-tasks proposals accept \(ref)`."
        }
        return ProposedOut(proposalId: row?.id, fingerprint: fp, title: parsed.title, lane: lane,
                           message: message)
    }
}
