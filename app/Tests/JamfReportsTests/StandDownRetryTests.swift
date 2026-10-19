import XCTest
@testable import JamfReports

/// A shared-workspace freshness stand-down ends the day only when today's summary exists.
final class StandDownRetryTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "standdown"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standdown-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func watcherAfterFreshnessStandDown() -> CollectHonestyWatcher {
        let watcher = CollectHonestyWatcher()
        watcher.observe(ReportEngine.standDownLine(
            reason: "[info] skipping collect — peer-mac collected 14 hours ago"))
        return watcher
    }

    func testAFreshnessStandDownIsRetriedWhileTodaysSummaryIsMissing() {
        let watcher = watcherAfterFreshnessStandDown()
        XCTAssertFalse(watcher.incomplete, "Run History still shows a clean stand-down")
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile))
        let outcome = ScheduleRunOutcome(
            exitCode: 0, incomplete: watcher.incomplete,
            retryCouldHelp: watcher.retryCouldHelp(profile: profile))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.endsRetries, "the tick must not stamp the day done")
    }

    func testAFreshnessStandDownEndsTheDayOnceTodaysSummaryExists() throws {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        try Data("{}".utf8).write(to: dir.appendingPathComponent("summary_\(today).json"))
        XCTAssertFalse(watcherAfterFreshnessStandDown().retryCouldHelp(profile: profile))
    }

    func testARunThatDidNotStandDownIsUnaffected() {
        let watcher = CollectHonestyWatcher()
        watcher.observe("[ok] collected")
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile))
    }
}
