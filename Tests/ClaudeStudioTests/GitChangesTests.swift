import XCTest
@testable import ClaudeStudio

final class GitChangesTests: XCTestCase {

    func testNumbersFollowTheHunkHeader() {
        let patch = [
            "@@ -10,4 +12,5 @@ func run()",
            " let a = 1",
            "-let b = 2",
            "+let b = 3",
            "+let c = 4",
            " return a",
        ]
        let lines = GitChanges.numbered(patch, untracked: false)
        XCTAssertEqual(lines.map(\.old), [nil, 10, 11, nil, nil, 12])
        XCTAssertEqual(lines.map(\.new), [nil, 12, nil, 13, 14, 15])
        XCTAssertEqual(lines.map(\.commentable), [false, true, true, true, true, true])
    }

    func testSecondHunkRestartsTheCount() {
        let patch = ["@@ -1 +1 @@", "-a", "+b", "@@ -40,2 +40,2 @@", " x"]
        let lines = GitChanges.numbered(patch, untracked: false)
        XCTAssertEqual(lines[4].old, 40)
        XCTAssertEqual(lines[4].new, 40)
    }

    func testUntrackedFileIsNumberedFromOne() {
        let lines = GitChanges.numbered(["+one", "+two", "… 3 more lines"], untracked: true)
        XCTAssertEqual(lines.map(\.new), [1, 2, nil])
        XCTAssertEqual(lines.map(\.commentable), [true, true, false])
    }

    func testNoNewlineMarkerIsNotCommentable() {
        let lines = GitChanges.numbered(["@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+b"], untracked: false)
        XCTAssertFalse(lines[2].commentable)
        XCTAssertEqual(lines[3].new, 1)
    }
}
