import XCTest
@testable import JamfReports

final class SchoolCollectPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(
        tiers: Set<CollectionTier>, force: Bool = false, lastRun: Date? = nil
    ) -> [ReportEngine.PlannedKind] {
        ReportEngine.planSchoolCollect(
            profile: "school", tiers: tiers, force: force, now: now) { _ in lastRun }
    }

    func test_scanOnlyRun_collectsNothing() {
        let planned = plan(tiers: [.scan])
        XCTAssertEqual(planned.count, ReportEngine.schoolCommandMatrix(profile: "school").count)
        XCTAssertTrue(planned.allSatisfy { $0.skip == .tierNotSelected(.inventory) })
    }

    func test_freshnessTiers_collectEveryKindWhenNeverCollected() {
        XCTAssertTrue(plan(tiers: [.refresh, .inventory]).allSatisfy { $0.skip == nil })
        XCTAssertTrue(plan(tiers: [.refresh]).allSatisfy { $0.skip == nil })
    }

    func test_recentCollect_isNotDue_unlessForced() {
        let anHourAgo = now.addingTimeInterval(-3_600)
        XCTAssertTrue(plan(tiers: [.refresh, .inventory], lastRun: anHourAgo)
            .allSatisfy { $0.skip?.isNotDue == true })
        XCTAssertTrue(plan(tiers: [.refresh, .inventory], force: true, lastRun: anHourAgo)
            .allSatisfy { $0.skip == nil })
    }

    func test_yesterdaysCollect_isDue() {
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertTrue(plan(tiers: [.refresh, .inventory], lastRun: yesterday)
            .allSatisfy { $0.skip == nil })
    }

    func test_planLines_nameTheSkipReason() {
        let lines = ReportEngine.collectPlanLines(
            profile: "school", fixedPlan: plan(tiers: [.scan]))
        XCTAssertTrue(lines[0].contains("collecting 0 sources"), lines[0])
        XCTAssertTrue(
            lines.contains { $0.contains("skipping 10 sources (tier inventory not selected)") },
            lines.joined(separator: "\n"))
    }
}
