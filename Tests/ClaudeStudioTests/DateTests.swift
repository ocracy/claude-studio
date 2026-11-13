import XCTest
@testable import ClaudeStudio

final class DateTests: XCTestCase {

    func testCompactAge() {
        XCTAssertEqual(Date().compactAge, "now")
        XCTAssertEqual(Date(timeIntervalSinceNow: -7 * 60).compactAge, "7m")
        XCTAssertEqual(Date(timeIntervalSinceNow: -5 * 3600).compactAge, "5h")
        XCTAssertEqual(Date(timeIntervalSinceNow: -30 * 86400).compactAge, "30d")
        XCTAssertEqual(Date(timeIntervalSinceNow: 120).compactAge, "now")
    }
}
