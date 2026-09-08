import XCTest
@testable import apple_tasks

final class AgentSeatTests: XCTestCase {
    func testFromArgvRecognizesCursorClaudeAgy() {
        let cursor = AgentSeat.from(argv: ["/usr/local/bin/agent", "--model", "gpt-5"])
        XCTAssertEqual(cursor.provider, "cursor")
        XCTAssertEqual(cursor.model, "gpt-5")

        let cursorAgent = AgentSeat.from(argv: ["cursor-agent"])
        XCTAssertEqual(cursorAgent.provider, "cursor")
        XCTAssertEqual(cursorAgent.model, "auto")

        let claude = AgentSeat.from(argv: ["claude", "--model", "sonnet"])
        XCTAssertEqual(claude.provider, "anthropic")
        XCTAssertEqual(claude.model, "sonnet")

        let agy = AgentSeat.from(argv: ["agy"])
        XCTAssertEqual(agy.provider, "antigravity")
        XCTAssertEqual(agy.model, "default")

        let antigravity = AgentSeat.from(argv: ["antigravity", "--model=opus"])
        XCTAssertEqual(antigravity.provider, "antigravity")
        XCTAssertEqual(antigravity.model, "opus")
    }
}
