import XCTest
@testable import ClaudeStudio

final class SessionDetailsTests: XCTestCase {

    func testDisplayNameOfModel() {
        XCTAssertEqual(SessionDetails.displayName(ofModel: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(SessionDetails.displayName(ofModel: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(SessionDetails.displayName(ofModel: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(SessionDetails.displayName(ofModel: "claude-opus-4-8[1m]"), "Opus 4.8")
        XCTAssertEqual(SessionDetails.displayName(ofModel: "claude-fable-5-1"), "Fable 5.1")
    }

    func testModeFromFooter() {
        XCTAssertEqual(SessionDetails.mode(in: ["", "  ⏵⏵ auto mode on (shift+tab to cycle)"], previous: nil), .auto)
        XCTAssertEqual(SessionDetails.mode(in: ["  ⏸ plan mode on (shift+tab to cycle)"], previous: .auto), .plan)
        XCTAssertEqual(SessionDetails.mode(in: ["  ⏵⏵ accept edits on"], previous: nil), .acceptEdits)
        XCTAssertEqual(SessionDetails.mode(in: ["  ⏵⏵ bypass permissions on"], previous: nil), .bypass)
        XCTAssertEqual(SessionDetails.mode(in: ["> ", "  ? for shortcuts"], previous: .plan), .standard)
    }

    func testContextOfALargeWindowModel() {
        var details = SessionDetails()
        details.modelID = "claude-opus-5-5"
        details.contextTokens = 217_000
        XCTAssertEqual(details.contextLimit, 1_000_000)
        XCTAssertEqual(details.contextLabel, "22% · 217k")
    }

    func testContextOfHaiku() {
        var details = SessionDetails()
        details.modelID = "claude-haiku-4-5-20251001"
        details.contextTokens = 50_000
        XCTAssertEqual(details.contextLimit, 200_000)
        XCTAssertEqual(details.contextLabel, "25% · 50k")
        details.contextTokens = 250_000
        XCTAssertEqual(details.contextLimit, 1_000_000)
    }

    func testNoContextWithoutTokens() {
        XCTAssertNil(SessionDetails().contextLabel)
        XCTAssertNil(SessionDetails().contextFraction)
    }

    func testParseTailReadsLatestUsageAndPlan() {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":90}}}"#,
            ##"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"# Plan\n- step"}}]}}"##,
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":999999}}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000}}}"#,
        ]
        var details = SessionDetails()
        SessionDetails.parseTail(lines.joined(separator: "\n"), into: &details)
        XCTAssertEqual(details.model, "Opus 5.5")
        XCTAssertEqual(details.contextTokens, 6000)
        XCTAssertEqual(details.plan, "# Plan\n- step")
        XCTAssertNil(details.todos)
    }

    func testParseTailPrefersTheNewestTaskList() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"old plan"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Read","status":"completed"},{"content":"Fix","status":"in_progress"},{"content":"Test","status":"pending"}]}}]}}"#,
        ]
        var details = SessionDetails()
        SessionDetails.parseTail(lines.joined(separator: "\n"), into: &details)
        XCTAssertNil(details.plan)
        XCTAssertEqual(details.todos?.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(details.todoProgress, "1/3")
    }
}
