import AppleTasksServerCore
import XCTest

final class RouteArgsTests: XCTestCase {
    func testTriageListBecomesInbox() {
        let route = RouteArgs.build(
            method: "POST",
            path: "/v1/triage",
            query: [:],
            body: Data(#"{"list":"Reminders"}"#.utf8)
        )
        guard case .cli(let args, _) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertTrue(containsPair(args, "--inbox", "Reminders"))
        XCTAssertFalse(args.contains("--list"))
        XCTAssertEqual(args.first, "triage")
    }

    func testTriageApplyAgentNotes() {
        let route = RouteArgs.build(
            method: "POST",
            path: "/v1/triage",
            query: [:],
            body: Data(#"{"apply":true,"agent":"local","notes":true}"#.utf8)
        )
        guard case .cli(let args, _) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertTrue(args.contains("--apply"))
        XCTAssertTrue(containsPair(args, "--agent", "local"))
        XCTAssertTrue(args.contains("--notes"))
    }

    func testDispatchEmptyBodyIsDryRun() {
        let route = RouteArgs.build(method: "POST", path: "/v1/dispatch", query: [:], body: Data(#"{}"#.utf8))
        guard case .cli(let args, let timeout) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertTrue(args.contains("--dry-run"))
        XCTAssertEqual(timeout, 60)
    }

    func testDispatchLiveRunOnlyWhenDryRunFalse() {
        let route = RouteArgs.build(
            method: "POST",
            path: "/v1/dispatch",
            query: [:],
            body: Data(#"{"dryRun":false}"#.utf8)
        )
        guard case .cli(let args, let timeout) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertFalse(args.contains("--dry-run"))
        XCTAssertEqual(timeout, 1800)
    }

    func testDispatchAllFlags() {
        let route = RouteArgs.build(
            method: "POST",
            path: "/v1/dispatch",
            query: [:],
            body: Data(#"{"dryRun":true,"agent":"cursor","list":"Code Tasks","reapOnly":true}"#.utf8)
        )
        guard case .cli(let args, let timeout) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertTrue(args.contains("--dry-run"))
        XCTAssertTrue(containsPair(args, "--agent", "cursor"))
        XCTAssertTrue(containsPair(args, "--list", "Code Tasks"))
        XCTAssertTrue(args.contains("--reap-only"))
        XCTAssertEqual(timeout, 60)
    }

    func testRunLogDefaultTail() {
        let route = RouteArgs.build(method: "GET", path: "/v1/runs/42/log", query: [:], body: Data())
        XCTAssertEqual(route, .runLog(id: "42", tailBytes: 262144))
    }

    func testRunLogTailQueryAndClamp() {
        let tailed = RouteArgs.build(method: "GET", path: "/v1/runs/42/log", query: ["tail": "1000"], body: Data())
        XCTAssertEqual(tailed, .runLog(id: "42", tailBytes: 1000))
        let clamped = RouteArgs.build(method: "GET", path: "/v1/runs/42/log", query: ["tail": "99999999"], body: Data())
        XCTAssertEqual(clamped, .runLog(id: "42", tailBytes: 4 * 1024 * 1024))
    }

    func testRunLogRejectsNonDigitIds() {
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/runs/../log", query: [:], body: Data()),
            .badRequest("bad run id")
        )
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/runs/abc/log", query: [:], body: Data()),
            .badRequest("bad run id")
        )
    }

    func testDispatchesQuery() {
        let route = RouteArgs.build(
            method: "GET",
            path: "/v1/dispatches",
            query: ["status": "running", "limit": "5"],
            body: Data()
        )
        guard case .cli(let args, _) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertEqual(args, ["dispatches", "--status", "running", "--limit", "5"])
    }

    func testDispatchCancel() {
        let route = RouteArgs.build(method: "POST", path: "/v1/dispatches/84/cancel", query: [:], body: Data())
        guard case .cli(let args, let timeout) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertEqual(args, ["dispatch-cancel", "84"])
        XCTAssertEqual(timeout, 30)
        XCTAssertEqual(
            RouteArgs.build(method: "POST", path: "/v1/dispatches/../cancel", query: [:], body: Data()),
            .badRequest("bad ledger id")
        )
        // GET is not a cancel.
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/dispatches/84/cancel", query: [:], body: Data()),
            .notFound
        )
    }

    func testDispatchDiscard() {
        let route = RouteArgs.build(method: "POST", path: "/v1/dispatches/84/discard", query: [:], body: Data())
        guard case .cli(let args, let timeout) = route else {
            return XCTFail("expected cli, got \(route)")
        }
        XCTAssertEqual(args, ["dispatch-discard", "84"])
        XCTAssertEqual(timeout, 60)
        XCTAssertEqual(
            RouteArgs.build(method: "POST", path: "/v1/dispatches/../discard", query: [:], body: Data()),
            .badRequest("bad ledger id")
        )
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/dispatches/84/discard", query: [:], body: Data()),
            .notFound
        )
    }

    func testHealthAndUnknown() {
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/health", query: [:], body: Data()),
            .health
        )
        XCTAssertEqual(
            RouteArgs.build(method: "GET", path: "/v1/nope", query: [:], body: Data()),
            .notFound
        )
    }

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0.0 == flag && $0.1 == value }
    }
}
