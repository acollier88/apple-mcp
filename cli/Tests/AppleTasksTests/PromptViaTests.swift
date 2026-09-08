import XCTest
@testable import apple_tasks

final class PromptViaTests: XCTestCase {
    let template = ["agent", "-p", "{prompt}", "--model", "auto"]
    let prompt = "Do the thing.\nSecond line."

    func testArgvInlinesPrompt() {
        let argv = Dispatch.renderArgv(template, prompt: prompt, via: .argv, promptFile: "/x")
        XCTAssertEqual(argv, ["agent", "-p", prompt, "--model", "auto"])
    }

    func testStdinDropsPromptEntry() {
        let argv = Dispatch.renderArgv(template, prompt: prompt, via: .stdin, promptFile: "/x")
        XCTAssertEqual(argv, ["agent", "-p", "--model", "auto"])
    }

    func testStdinBlanksEmbeddedPrompt() {
        let argv = Dispatch.renderArgv(["sh", "-c", "run '{prompt}'"], prompt: prompt, via: .stdin, promptFile: "/x")
        XCTAssertEqual(argv, ["sh", "-c", "run ''"])
    }

    func testFileSubstitutesPath() {
        let argv = Dispatch.renderArgv(["codex", "exec", "--prompt-file", "{promptFile}", "{prompt}"],
                                       prompt: prompt, via: .file, promptFile: "/runs/7.prompt")
        XCTAssertEqual(argv, ["codex", "exec", "--prompt-file", "/runs/7.prompt"])
    }

    func testPromptViaDecodesWithDefaultNil() throws {
        let json = #"{"agents":{"a":{"command":["x","{prompt}"]},"b":{"command":["y"],"promptVia":"stdin"}}}"#
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.agents["a"]?.promptVia)
        XCTAssertEqual(config.agents["b"]?.promptVia, .stdin)
    }

    func testPromptViaRejectsUnknownValue() {
        let json = #"{"agents":{"a":{"command":["x"],"promptVia":"carrier-pigeon"}}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8)))
    }
}
