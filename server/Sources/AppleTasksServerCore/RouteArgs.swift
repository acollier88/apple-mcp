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
            if let s = query["status"], !s.isEmpty { args.append(option("--status", s)) }
            if let l = query["limit"], !l.isEmpty { args.append(option("--limit", l)) }
            return .cli(args: args, timeout: 30)
        case ("GET", "/v1/log"):
            var args = ["log"]
            if let l = query["limit"], !l.isEmpty { args.append(option("--limit", l)) }
            if let s = query["since"], !s.isEmpty { args.append(option("--since", s)) }
            if let t = query["task"], !t.isEmpty { args.append(option("--task", t)) }
            if let c = query["caller"], !c.isEmpty { args.append(option("--caller", c)) }
            return .cli(args: args, timeout: 30)
        case ("POST", "/v1/dispatch"):
            return dispatch(body)
        case ("POST", let p) where p.hasPrefix("/v1/dispatches/") && p.hasSuffix("/cancel"):
            let id = String(p.dropFirst("/v1/dispatches/".count).dropLast("/cancel".count))
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return .badRequest("bad ledger id") }
            return .cli(args: ["dispatch-cancel", id], timeout: 30)
        case ("POST", let p) where p.hasPrefix("/v1/dispatches/") && p.hasSuffix("/discard"):
            let id = String(p.dropFirst("/v1/dispatches/".count).dropLast("/discard".count))
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return .badRequest("bad ledger id") }
            return .cli(args: ["dispatch-discard", id], timeout: 60)
        case ("POST", "/v1/triage"):
            return triage(body)
        case ("GET", let p) where p.hasPrefix("/v1/runs/") && p.hasSuffix("/log"):
            return runLog(path: p, query: query)
        default:
            return .notFound
        }
    }

    /// `--flag=value`: swift-argument-parser rejects `--flag -x` ("Missing
    /// value") but accepts the attached form for any value, so a query or
    /// body value starting with `-` is passed as a value, never as an
    /// option. Callers only pass non-empty values (`--flag=` is itself
    /// "missing value"). Same rule as `opt()` in mcp/src/lib.ts.
    static func option(_ flag: String, _ value: String) -> String {
        "\(flag)=\(value)"
    }

    private static func jsonObject(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private static func dispatch(_ body: Data) -> Route {
        let obj = jsonObject(body)
        var args = ["dispatch"]
        let live = (obj["dryRun"] as? Bool) == false
        if !live { args.append("--dry-run") }
        if let agent = obj["agent"] as? String, !agent.isEmpty { args.append(option("--agent", agent)) }
        if let list = obj["list"] as? String, !list.isEmpty { args.append(option("--list", list)) }
        if obj["reapOnly"] as? Bool == true { args.append("--reap-only") }
        return .cli(args: args, timeout: live ? 1800 : 60)
    }

    private static func triage(_ body: Data) -> Route {
        let obj = jsonObject(body)
        var args = ["triage"]
        if obj["apply"] as? Bool == true { args.append("--apply") }
        if let list = obj["list"] as? String, !list.isEmpty { args.append(option("--inbox", list)) }
        if let agent = obj["agent"] as? String, !agent.isEmpty { args.append(option("--agent", agent)) }
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
