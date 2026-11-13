import XCTest
@testable import ClaudeStudio

final class PullRequestsTests: XCTestCase {

    private func status(_ json: String) -> PullRequests.Status? {
        PullRequests.parse(Data(json.utf8))
    }

    func testPassingChecks() {
        let pull = status(#"{"number":42,"title":"Fix","url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"SUCCESS"}]}"#)
        XCTAssertEqual(pull?.number, 42)
        XCTAssertEqual(pull?.state, .open)
        XCTAssertEqual(pull?.checks, .passed)
        XCTAssertEqual(pull?.total, 2)
    }

    func testAFailureWinsOverPending() {
        let pull = status(#"{"number":1,"url":"https://x/1","state":"OPEN","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":""},{"status":"COMPLETED","conclusion":"FAILURE"}]}"#)
        XCTAssertEqual(pull?.checks, .failed)
        XCTAssertEqual(pull?.failing, 1)
    }

    func testRunningChecksArePending() {
        let pull = status(#"{"number":1,"url":"https://x/1","state":"OPEN","statusCheckRollup":[{"status":"QUEUED","conclusion":""},{"state":"PENDING"}]}"#)
        XCTAssertEqual(pull?.checks, .pending)
    }

    func testStates() {
        XCTAssertEqual(status(#"{"number":1,"url":"https://x/1","state":"OPEN","isDraft":true}"#)?.state, .draft)
        XCTAssertEqual(status(#"{"number":1,"url":"https://x/1","state":"MERGED"}"#)?.state, .merged)
        XCTAssertEqual(status(#"{"number":1,"url":"https://x/1","state":"CLOSED"}"#)?.checks, PullRequests.Status.Checks.none)
    }

    func testNoPullRequest() {
        XCTAssertNil(status("no pull requests found for branch \"main\""))
        XCTAssertNil(status(#"{"title":"no number"}"#))
    }
}
