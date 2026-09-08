import AppleTasksServerCore
import XCTest

final class HTTPParseTests: XCTestCase {
    func testSplitsRequestLineHeadersAndBody() {
        let raw = Data("POST /v1/triage?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8\r\nX-A: b\r\n\r\n{\"ok\":1}".utf8)
        guard case .complete(let req) = HTTPRequest.parse(raw) else {
            return XCTFail("expected complete request")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/triage?x=1")
        XCTAssertEqual(req.pathOnly, "/v1/triage")
        XCTAssertEqual(req.query["x"], "1")
        XCTAssertEqual(req.headers["host"], "localhost")
        XCTAssertEqual(req.headers["x-a"], "b")
        XCTAssertEqual(req.body, Data(#"{"ok":1}"#.utf8))
    }

    func testBodyArrivingInTwoChunks() {
        let first = Data("POST /v1/x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe".utf8)
        XCTAssertEqual(HTTPRequest.parse(first), .incomplete)
        var second = first
        second.append(Data("llo".utf8))
        guard case .complete(let req) = HTTPRequest.parse(second) else {
            return XCTFail("expected complete after second chunk")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/x")
        XCTAssertEqual(req.body, Data("hello".utf8))
    }

    func testOversizedHeaderBlock() {
        var data = Data("GET /v1/health HTTP/1.1\r\nX-Pad: ".utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: HTTPLimits.maxHeaderBlockBytes))
        XCTAssertEqual(HTTPRequest.parse(data), .headersTooLarge)
    }

    func testOversizedDeclaredContentLength() {
        let len = HTTPLimits.maxContentLength + 1
        let raw = Data("POST /v1/dispatch HTTP/1.1\r\nContent-Length: \(len)\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequest.parse(raw), .payloadTooLarge)
        XCTAssertEqual(parseContentLength(String(len)), .tooLarge)
        XCTAssertEqual(parseContentLength("16"), .value(16))
        XCTAssertEqual(parseContentLength("nope"), .invalid)
        XCTAssertNil(parseContentLength(nil))
    }
}
