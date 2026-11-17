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

    func testLedgerCommandOmitsPromptForArgv() {
        let command = Dispatch.ledgerCommand(template, via: .argv, promptFile: "{promptFile}")
        XCTAssertEqual(command, "agent -p \(Dispatch.ledgerPromptMarker) --model auto")
        XCTAssertFalse(command.contains("Do the thing"))
    }

    func testLedgerCommandEmbeddedPromptAlsoMarked() {
        let command = Dispatch.ledgerCommand(["sh", "-c", "run '{prompt}'"], via: .argv, promptFile: "/x")
        XCTAssertEqual(command, "sh -c run '\(Dispatch.ledgerPromptMarker)'")
    }

    func testLedgerCommandMatchesArgvForStdinAndFile() {
        XCTAssertEqual(Dispatch.ledgerCommand(template, via: .stdin, promptFile: "/x"),
                       Dispatch.renderArgv(template, prompt: prompt, via: .stdin, promptFile: "/x").joined(separator: " "))
        let fileTemplate = ["codex", "exec", "--prompt-file", "{promptFile}"]
        XCTAssertEqual(Dispatch.ledgerCommand(fileTemplate, via: .file, promptFile: "/runs/7.prompt"),
                       "codex exec --prompt-file /runs/7.prompt")
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
