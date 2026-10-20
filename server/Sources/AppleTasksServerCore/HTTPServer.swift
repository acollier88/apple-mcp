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

public enum HTTPLimits {
    public static let maxHeaderBlockBytes = 16 * 1024
    public static let maxContentLength = 1 * 1024 * 1024
    public static let requestTimeout: TimeInterval = 10
    public static let defaultLogTailBytes = 262_144
    public static let maxLogTailBytes = 4 * 1024 * 1024
    public static let maxConcurrentCLI = 4
    public static let cliSlotWait: TimeInterval = 1
}

public enum HTTPParseOutcome: Equatable {
    case incomplete
    case complete(HTTPRequest)
    case headersTooLarge
    case payloadTooLarge
}

/// Tiny HTTP/1.1 listener. No EventKit. Routes exec the apple-tasks CLI.
public final class ServeHTTP: @unchecked Sendable {
    private let config: ServeConfig
    private var listener: NWListener?
    private let cliSlots = DispatchSemaphore(value: HTTPLimits.maxConcurrentCLI)

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
        receive(connection, buffer: Data(), incoming: RequestReadState())
    }

    private func receive(_ connection: NWConnection, buffer: Data, incoming: RequestReadState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            incoming.lock.lock()
            let alreadyDone = incoming.finished
            incoming.lock.unlock()
            if alreadyDone { return }

            var buf = buffer
            if let data { buf.append(data) }

            switch HTTPRequest.parse(buf) {
            case .complete(let req):
                // Stop the 10s read timer before exec; routing a live dispatch can take minutes.
                guard self.claim(incoming) else { return }
                self.send(connection, self.route(req))
            case .headersTooLarge:
                self.finish(connection, incoming: incoming, response: .error(431, "headers too large", code: "headers_too_large"))
            case .payloadTooLarge:
                self.finish(connection, incoming: incoming, response: .error(413, "payload too large", code: "payload_too_large"))
            case .incomplete:
                if isComplete || error != nil {
                    self.finish(connection, incoming: incoming, response: nil)
                    return
                }
                self.armRequestTimeoutIfNeeded(connection, incoming: incoming, buffer: buf)
                self.receive(connection, buffer: buf, incoming: incoming)
            }
        }
    }

    private func armRequestTimeoutIfNeeded(_ connection: NWConnection, incoming: RequestReadState, buffer: Data) {
        guard !buffer.isEmpty else { return }
        incoming.lock.lock()
        defer { incoming.lock.unlock() }
        guard incoming.timeoutWork == nil, !incoming.finished else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.finish(connection, incoming: incoming, response: .error(408, "timeout", code: "timeout"))
        }
        incoming.timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + HTTPLimits.requestTimeout, execute: work)
    }

    private func claim(_ incoming: RequestReadState) -> Bool {
        incoming.lock.lock()
        defer { incoming.lock.unlock() }
        if incoming.finished { return false }
        incoming.finished = true
        incoming.timeoutWork?.cancel()
        return true
    }

    private func send(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ connection: NWConnection, incoming: RequestReadState, response: HTTPResponse?) {
        guard claim(incoming) else { return }
        if let response {
            send(connection, response)
        } else {
            connection.cancel()
        }
    }

    public func route(_ req: HTTPRequest) -> HTTPResponse {
        let built = RouteArgs.build(method: req.method, path: req.pathOnly, query: req.query, body: req.body)
        if case .health = built {
            return .json(200, #"{"ok":true,"service":"apple-tasks-server"}"#)
        }
        if !authorized(req) {
            return .error(401, "unauthorized", code: "unauthorized")
        }
        switch built {
        case .health:
            return .json(200, #"{"ok":true,"service":"apple-tasks-server"}"#)
        case .cli(let args, let timeout):
            return execCLI(args, timeout: timeout)
        case .runLog(let id, let tailBytes):
            return readRunLog(id: id, tailBytes: tailBytes)
        case .notFound:
            return .error(404, "not found", code: "not_found")
        case .badRequest(let message):
            return .error(400, message, code: "bad_request")
        }
    }

    private func execCLI(_ args: [String], timeout: TimeInterval) -> HTTPResponse {
        if cliSlots.wait(timeout: .now() + HTTPLimits.cliSlotWait) == .timedOut {
            return .error(503, "busy", code: "busy")
        }
        defer { cliSlots.signal() }
        do {
            let out = try AppleTasksCLI.run(args, timeout: timeout)
            return .raw(200, out)
        } catch let err as CLIError {
            return cliFailure(err)
        } catch {
            return .error(502, error.localizedDescription, code: "cli_failed")
        }
    }

    private func cliFailure(_ err: CLIError) -> HTTPResponse {
        switch err {
        case .timeout:
            return .error(502, err.description, code: "timeout")
        case .failed(let code, _):
            return .error(502, err.description, code: "cli_failed", exitCode: code)
        case .binaryMissing:
            return .error(502, err.description, code: "cli_failed")
        }
    }

    private func readRunLog(id: String, tailBytes: Int) -> HTTPResponse {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/runs/\(id).log")
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
            try handle.seek(toOffset: start)
            let data = (try handle.readToEnd()) ?? Data()
            // A tail can start mid-codepoint; decode lossily rather than 404.
            return .text(200, String(decoding: data, as: UTF8.self))
        } catch {
            return .error(404, "run log not found", code: "not_found")
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        let header = req.headers["authorization"] ?? ""
        let presented = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : ""
        return constantTimeEqual(presented, config.token)
    }
}

private final class RequestReadState: @unchecked Sendable {
    let lock = NSLock()
    var finished = false
    var timeoutWork: DispatchWorkItem?
}

public struct HTTPRequest: Sendable, Equatable {
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

    public static func parse(_ data: Data) -> HTTPParseOutcome {
        let crlf = Data("\r\n\r\n".utf8)
        if let range = data.range(of: crlf) {
            let headerBlockEnd = range.upperBound - data.startIndex
            if headerBlockEnd > HTTPLimits.maxHeaderBlockBytes {
                return .headersTooLarge
            }
            let head = data.subdata(in: data.startIndex..<range.lowerBound)
            let rawBody = data.subdata(in: range.upperBound..<data.endIndex)
            guard let text = String(data: head, encoding: .utf8) else { return .incomplete }
            let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else { return .incomplete }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return .incomplete }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            let body: Data
            if let declared = parseContentLength(headers["content-length"]) {
                switch declared {
                case .invalid:
                    body = rawBody
                case .tooLarge:
                    return .payloadTooLarge
                case .value(let len):
                    if rawBody.count < len {
                        return .incomplete
                    }
                    body = rawBody.prefix(len)
                }
            } else {
                body = rawBody
            }
            return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body))
        }
        if data.count > HTTPLimits.maxHeaderBlockBytes {
            return .headersTooLarge
        }
        return .incomplete
    }
}

public enum ContentLength: Equatable {
    case value(Int)
    case tooLarge
    case invalid
}

/// Declared Content-Length: numeric and ≤ 1 MiB, numeric but too big, or not a number.
public func parseContentLength(_ raw: String?) -> ContentLength? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.allSatisfy(\.isNumber) else { return .invalid }
    guard let len = Int(trimmed) else { return .tooLarge }
    if len > HTTPLimits.maxContentLength { return .tooLarge }
    return .value(len)
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
    }

    public static func error(_ status: Int, _ message: String, code: String, exitCode: Int32? = nil) -> HTTPResponse {
        .json(status, jsonError(message, code: code, exitCode: exitCode))
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

func jsonError(_ message: String, code: String, exitCode: Int32? = nil) -> String {
    var obj: [String: Any] = ["error": message, "code": code]
    if let exitCode {
        obj["exitCode"] = Int(exitCode)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"error":"internal","code":"cli_failed"}"#
    }
    return text
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
