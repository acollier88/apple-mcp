import Foundation
import Network

public struct ServeConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var token: String

    public init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Tiny HTTP/1.1 listener. No EventKit. Routes exec the apple-tasks CLI.
public final class ServeHTTP: @unchecked Sendable {
    private let config: ServeConfig
    private var listener: NWListener?

    public init(config: ServeConfig) {
        self.config = config
    }

    public func start() throws {
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw BindError.invalidAddress(String(config.port))
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Port-only listen is IPv6 `*` on Darwin and often misses Tailscale IPv4 (100.x).
        if let v4 = IPv4Address(config.host) {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(v4), port: port)
        }
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global())
        self.listener = listener
        FileHandle.standardError.write(Data("apple-tasks-server listening on \(config.host):\(config.port)\n".utf8))
    }

    public func runForever() throws {
        try start()
        dispatchMain()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                let response = self.route(req)
                connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buf)
        }
    }

    public func route(_ req: HTTPRequest) -> HTTPResponse {
        if req.path == "/v1/health" && req.method == "GET" {
            return .json(200, #"{"ok":true,"service":"apple-tasks-server"}"#)
        }
        if !authorized(req) {
            return .json(401, #"{"error":"unauthorized"}"#)
        }
        do {
            switch (req.method, req.pathOnly) {
            case ("GET", "/v1/dispatches"):
                var args = ["dispatches"]
                if let s = req.query["status"], !s.isEmpty { args += ["--status", s] }
                if let l = req.query["limit"], !l.isEmpty { args += ["--limit", l] }
                let out = try AppleTasksCLI.run(args, timeout: 30)
                return .raw(200, out)
            case ("GET", "/v1/log"):
                var args = ["log"]
                if let l = req.query["limit"], !l.isEmpty { args += ["--limit", l] }
                if let s = req.query["since"], !s.isEmpty { args += ["--since", s] }
                if let t = req.query["task"], !t.isEmpty { args += ["--task", t] }
                if let c = req.query["caller"], !c.isEmpty { args += ["--caller", c] }
                let out = try AppleTasksCLI.run(args, timeout: 30)
                return .raw(200, out)
            case ("POST", "/v1/dispatch"):
                let body = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
                var args = ["dispatch"]
                if body["dryRun"] as? Bool == true { args.append("--dry-run") }
                if let agent = body["agent"] as? String, !agent.isEmpty { args += ["--agent", agent] }
                if let list = body["list"] as? String, !list.isEmpty { args += ["--list", list] }
                let timeout: TimeInterval = (body["dryRun"] as? Bool == true) ? 60 : 1800
                let out = try AppleTasksCLI.run(args, timeout: timeout)
                return .raw(200, out)
            case ("GET", let path) where path.hasPrefix("/v1/runs/") && path.hasSuffix("/log"):
                let id = path.dropFirst("/v1/runs/".count).dropLast("/log".count)
                guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else {
                    return .json(400, #"{"error":"bad run id"}"#)
                }
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/apple-tasks/runs/\(id).log")
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                    return .json(404, #"{"error":"run log not found"}"#)
                }
                return .text(200, text)
            case ("POST", "/v1/triage"):
                let body = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
                var args = ["triage"]
                if body["apply"] as? Bool == true { args.append("--apply") }
                if let list = body["list"] as? String, !list.isEmpty { args += ["--list", list] }
                let out = try AppleTasksCLI.run(args, timeout: 120)
                return .raw(200, out)
            default:
                return .json(404, #"{"error":"not found"}"#)
            }
        } catch {
            return .json(502, jsonError(error.localizedDescription))
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        let header = req.headers["authorization"] ?? ""
        let presented = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : ""
        return constantTimeEqual(presented, config.token)
    }
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public var pathOnly: String {
        String(path.split(separator: "?", maxSplits: 1).first ?? Substring(path))
    }

    public var query: [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let k = parts.first else { continue }
            let v = parts.count > 1 ? String(parts[1]) : ""
            out[String(k)] = v.removingPercentEncoding ?? v
        }
        return out
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.endIndex)
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if let len = headers["content-length"].flatMap(Int.init), body.count < len {
            return nil
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
    }

    public static func raw(_ status: Int, _ body: String) -> HTTPResponse {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? "[]" : trimmed
        return .json(status, payload)
    }

    public static func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    public func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

func jsonError(_ message: String) -> String {
    let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"error\":\"\(escaped)\"}"
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
    let n = max(x.count, y.count)
    for i in 0..<n {
        let av = i < x.count ? x[i] : 0
        let bv = i < y.count ? y[i] : 0
        diff |= av ^ bv
    }
    return diff == 0 && !b.isEmpty
}
