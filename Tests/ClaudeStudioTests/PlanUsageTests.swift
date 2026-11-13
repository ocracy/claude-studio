import XCTest
@testable import ClaudeStudio

final class PlanUsageTests: XCTestCase {

    func testReadsTheLimitsClaudeCodeCaches() {
        let json = #"""
        {"cachedUsageUtilization":{"fetchedAtMs":1793100868591,"utilization":{"limits":[
          {"kind":"session","percent":2,"resets_at":"2026-10-27T16:10:00.458041+00:00"},
          {"kind":"weekly_all","percent":20,"resets_at":"2026-11-01T06:00:00.458064+00:00"},
          {"kind":"weekly_scoped","percent":0,"resets_at":"2026-11-01T06:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":""}}},
          {"kind":"something_new","percent":50}
        ]}}}
        """#
        let parsed = PlanUsage.parse(Data(json.utf8))
        XCTAssertEqual(parsed.limits.map(\.id), ["session", "weekly", "scoped:Fable"])
        XCTAssertEqual(parsed.limits.map(\.percent), [2, 20, 0])
        XCTAssertNotNil(parsed.limits[0].resetsAt)
        XCTAssertNotNil(parsed.limits[2].resetsAt)
        XCTAssertEqual(parsed.fetchedAt?.timeIntervalSince1970 ?? 0, 1_793_100_868.591, accuracy: 0.001)
    }

    func testMissingCacheGivesNothing() {
        XCTAssertTrue(PlanUsage.parse(Data(#"{"projects":{}}"#.utf8)).limits.isEmpty)
        XCTAssertTrue(PlanUsage.parse(Data("not json".utf8)).limits.isEmpty)
    }

    func testRemainingTime() {
        let now = Date(timeIntervalSince1970: 0)
        func limit(_ seconds: TimeInterval) -> PlanUsage.Limit {
            PlanUsage.Limit(kind: .session, percent: 1, resetsAt: Date(timeIntervalSince1970: seconds))
        }
        XCTAssertEqual(limit(3 * 3600 + 39 * 60 + 30).remaining(from: now), "3h 39m")
        XCTAssertEqual(limit(5 * 86400 + 5 * 3600).remaining(from: now), "5d 5h")
        XCTAssertEqual(limit(12 * 60).remaining(from: now), "12m")
        XCTAssertEqual(limit(-60).remaining(from: now), "0m")
        XCTAssertNil(PlanUsage.Limit(kind: .weekly, percent: 1, resetsAt: nil).remaining(from: now))
    }
}
