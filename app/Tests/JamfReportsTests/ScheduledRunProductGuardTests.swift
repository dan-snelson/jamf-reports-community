import Foundation
import XCTest
@testable import JamfReports

/// A schedule on a profile of another product ends its retries, writes nothing in the
/// workspace and posts nothing, while an unresolved or Jamf Pro profile runs as before.
final class ScheduledRunProductGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "protect-only"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-product-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "guard", profile: profile, schedule: "manual", cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: nil, multiTarget: nil, tiers: nil, excludedProfiles: nil)
    }

    private var automation: URL {
        root.appendingPathComponent("Jamf-Reports/\(profile)/automation")
    }

    func testARefusedScheduleSucceedsEndsItsRetriesAndLeavesNoRecord() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        for mode in [Schedule.RunMode.jamfCLIFull, .snapshotOnly, .backup] {
            let outcome = await runSchedule(schedule(mode), verbose: false)
            XCTAssertEqual(outcome.exitCode, 0, "\(mode)")
            XCTAssertTrue(outcome.endsRetries, "\(mode): the tick must not retry it")
            XCTAssertTrue(outcome.succeeded, "\(mode)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: automation.path),
                       "the refusal created automation/ in the workspace")
    }

    func testAScheduleThatReadsOnlyTheCacheIsNotRefused() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        _ = await runSchedule(schedule(.jamfCLIOnly), verbose: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: automation.path),
                      "jamf-cli-only sends no command and still records its run")
    }

    func testRefusalIsTheSameRuleAsTheRouterAndSchedulesAdd() throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        XCTAssertNotNil(CollectRouter.proRunRefusal(
            profile: profile, operation: "Collect", config: nil))
        let school = try ConfigLoader.loadFromString(
            "school_cli:\n  enabled: true\n  profile: \(profile)\n")
        XCTAssertNil(CollectRouter.proRunRefusal(
            profile: profile, operation: "Collect", config: school),
                     "a School workspace is not a Pro run")
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: profile, allProfiles: false, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: nil, disabled: false))
        XCTAssertNoThrow(try Schedules.Add.record(
            name: "x", profile: profile, allProfiles: true, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: nil, disabled: false))
    }
}

/// A refused schedule writes no status file, so it must not reach the dead-man switch.
final class ScheduledRunHealthProductGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "protect-only"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-health-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func schedule(_ mode: Schedule.RunMode, multi: Bool = false) -> Schedule {
        Schedule(
            name: "guard-\(mode.rawValue)", profile: multi ? "" : profile, schedule: "Daily 06:20",
            cadence: "custom", mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.x.\(mode.rawValue)",
            multiTarget: multi ? MultiTarget(scope: .all) : nil, tiers: nil, excludedProfiles: nil)
    }

    func testARefusedScheduleIsFailingWithTheReasonNeverOverdue() throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let schedules = [
            schedule(.jamfCLIFull), schedule(.snapshotOnly), schedule(.backup),
            schedule(.jamfCLIOnly), schedule(.snapshotOnly, multi: true)]
        let now = Date()
        let inputs = LaunchAgentService.healthInputs(
            schedules: schedules, statusProfile: nil, now: now)
        XCTAssertEqual(inputs.count, 5)
        XCTAssertEqual(inputs.map { $0.refusal != nil }, [true, true, true, false, false],
                       "a cache-only and an all-profiles schedule are not refused")
        // Two days on, with no status file anywhere: the old reading was overdue.
        let issues = AutomationHealth.evaluate(
            inputs: inputs, now: now.addingTimeInterval(86_400 * 2))
        let refused = issues.filter { $0.profile == profile && $0.reason != nil }
        XCTAssertEqual(refused.count, 3)
        XCTAssertTrue(refused.allSatisfy { $0.kind == .failing })
        XCTAssertTrue(refused.allSatisfy { $0.reason?.contains("'\(profile)' is a Jamf Protect profile") == true })
        XCTAssertTrue(issues.filter { $0.kind == .overdue }.allSatisfy { $0.reason == nil })
    }

    func testAJamfProScheduleIsNotRefused() throws {
        try ProductGuardSeed.seed(profile: profile, product: "pro", in: root)
        XCTAssertNil(LaunchAgentService.healthInputs(
            schedules: [schedule(.jamfCLIFull)], statusProfile: nil).first?.refusal)
    }
}
