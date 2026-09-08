import Foundation

public enum Route: Equatable {
    case health
    case cli(args: [String], timeout: TimeInterval)
    case runLog(id: String, tailBytes: Int)
    case notFound
    case badRequest(String)
}

public enum RouteArgs {
    public static func build(method: String, path: String, query: [String: String], body: Data) -> Route {
        switch (method, path) {
        case ("GET", "/v1/health"):
            return .health
        case ("GET", "/v1/dispatches"):
            var args = ["dispatches"]
            if let s = query["status"], !s.isEmpty { args += ["--status", s] }
            if let l = query["limit"], !l.isEmpty { args += ["--limit", l] }
            return .cli(args: args, timeout: 30)
        case ("GET", "/v1/log"):
            var args = ["log"]
            if let l = query["limit"], !l.isEmpty { args += ["--limit", l] }
            if let s = query["since"], !s.isEmpty { args += ["--since", s] }
            if let t = query["task"], !t.isEmpty { args += ["--task", t] }
            if let c = query["caller"], !c.isEmpty { args += ["--caller", c] }
            return .cli(args: args, timeout: 30)
        case ("POST", "/v1/dispatch"):
            return dispatch(body)
        case ("POST", let p) where p.hasPrefix("/v1/dispatches/") && p.hasSuffix("/cancel"):
            let id = String(p.dropFirst("/v1/dispatches/".count).dropLast("/cancel".count))
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return .badRequest("bad ledger id") }
            return .cli(args: ["dispatch-cancel", id], timeout: 30)
        case ("POST", "/v1/triage"):
            return triage(body)
        case ("GET", let p) where p.hasPrefix("/v1/runs/") && p.hasSuffix("/log"):
            return runLog(path: p, query: query)
        default:
            return .notFound
        }
    }

    private static func jsonObject(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private static func dispatch(_ body: Data) -> Route {
        let obj = jsonObject(body)
        var args = ["dispatch"]
        let live = (obj["dryRun"] as? Bool) == false
        if !live { args.append("--dry-run") }
        if let agent = obj["agent"] as? String, !agent.isEmpty { args += ["--agent", agent] }
        if let list = obj["list"] as? String, !list.isEmpty { args += ["--list", list] }
        if obj["reapOnly"] as? Bool == true { args.append("--reap-only") }
        return .cli(args: args, timeout: live ? 1800 : 60)
    }

    private static func triage(_ body: Data) -> Route {
        let obj = jsonObject(body)
        var args = ["triage"]
        if obj["apply"] as? Bool == true { args.append("--apply") }
        if let list = obj["list"] as? String, !list.isEmpty { args += ["--inbox", list] }
        if let agent = obj["agent"] as? String, !agent.isEmpty { args += ["--agent", agent] }
        if obj["notes"] as? Bool == true { args.append("--notes") }
        return .cli(args: args, timeout: 120)
    }

    private static func runLog(path: String, query: [String: String]) -> Route {
        let id = String(path.dropFirst("/v1/runs/".count).dropLast("/log".count))
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            return .badRequest("bad run id")
        }
        return .runLog(id: id, tailBytes: tailBytes(query["tail"]))
    }

    private static func tailBytes(_ raw: String?) -> Int {
        let fallback = HTTPLimits.defaultLogTailBytes
        guard let raw, let n = Int(raw), n >= 0 else { return fallback }
        return min(n, HTTPLimits.maxLogTailBytes)
    }
}
