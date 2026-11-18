import XCTest
@testable import apple_tasks

final class DispatchObservabilityTests: XCTestCase {
    func testQuietEmptyPassPrintsNothing() {
        XCTAssertTrue(Dispatch.suppressQuietStdout(
            quiet: true, reportCount: 0, noiseOnly: true, lastHash: nil, hash: "abc"))
        XCTAssertTrue(Dispatch.suppressQuietStdout(
            quiet: true, reportCount: 0, noiseOnly: true, lastHash: "other", hash: "abc"))
    }

    func testQuietRepeatNoiseIsSilentAndFirstNoisePrints() {
        XCTAssertTrue(Dispatch.suppressQuietStdout(
            quiet: true, reportCount: 2, noiseOnly: true, lastHash: "same", hash: "same"))
        XCTAssertFalse(Dispatch.suppressQuietStdout(
            quiet: true, reportCount: 2, noiseOnly: true, lastHash: nil, hash: "same"))
        XCTAssertFalse(Dispatch.suppressQuietStdout(
            quiet: true, reportCount: 1, noiseOnly: false, lastHash: "same", hash: "same"))
    }

    func testInteractivePassAlwaysPrints() {
        XCTAssertFalse(Dispatch.suppressQuietStdout(
            quiet: false, reportCount: 0, noiseOnly: true, lastHash: "same", hash: "same"))
    }

    func testGlobalMaxConcurrentDecodesAboveOne() throws {
        let config = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{},"maxConcurrent":3}"#.utf8))
        XCTAssertEqual(config.maxConcurrent, 3)
    }
}
