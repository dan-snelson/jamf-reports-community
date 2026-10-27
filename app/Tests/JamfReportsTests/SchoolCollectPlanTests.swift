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

    private func blueprintsSkip(missing: Bool, force: Bool = false) -> ReportEngine.CollectSkipReason? {
        ReportEngine.planSchoolCollect(
            profile: "school", tiers: [.refresh, .inventory], force: force, now: now,
            platformFieldsMissing: missing) { _ in nil }
            .first { $0.kind == ReportEngine.schoolBlueprintsKind }?.skip
    }

    func test_blueprints_skipWithoutPlatformFields_otherKindsStillRun() {
        XCTAssertEqual(blueprintsSkip(missing: true), .schoolNoPlatform)
        XCTAssertEqual(blueprintsSkip(missing: true, force: true), .schoolNoPlatform)
        let others = ReportEngine.planSchoolCollect(
            profile: "school", tiers: [.refresh], force: false, now: now,
            platformFieldsMissing: true) { _ in nil }
            .filter { $0.kind != ReportEngine.schoolBlueprintsKind }
        XCTAssertTrue(others.allSatisfy { $0.skip == nil })
    }

    func test_blueprints_collectWhenPlatformFieldsPresentOrUnknown() {
        XCTAssertNil(blueprintsSkip(missing: false))
    }

    func test_blueprints_skipWording_andPlanLine() {
        let text = ReportEngine.CollectSkipReason.schoolNoPlatform.skipDetail
        XCTAssertEqual(
            text,
            "the Jamf School profile has no Platform API fields (Data Sources › Add Platform API)")
        let plan = ReportEngine.planSchoolCollect(
            profile: "school", tiers: [.refresh], force: true, now: now,
            platformFieldsMissing: true) { _ in nil }
        let lines = ReportEngine.collectPlanLines(profile: "school", fixedPlan: plan)
        XCTAssertTrue(lines.contains {
            $0.contains("skipping 1 source (the School profile has no Platform API fields): "
                + "school-blueprints")
        }, lines.joined(separator: "\n"))
    }

    func test_blueprintsCommand_isTheSchoolBlueprintsList() {
        let entry = ReportEngine.schoolCommandMatrix(profile: "s")
            .first { $0.kind == "school-blueprints" }
        XCTAssertEqual(entry?.args, ["-p", "s", "school", "blueprints", "list", "--output", "json"])
    }

    func test_planLines_nameTheSkipReason() {
        let lines = ReportEngine.collectPlanLines(
            profile: "school", fixedPlan: plan(tiers: [.scan]))
        XCTAssertTrue(lines[0].contains("collecting 0 sources"), lines[0])
        XCTAssertTrue(
            lines.contains { $0.contains("skipping 11 sources (tier inventory not selected)") },
            lines.joined(separator: "\n"))
    }
}
