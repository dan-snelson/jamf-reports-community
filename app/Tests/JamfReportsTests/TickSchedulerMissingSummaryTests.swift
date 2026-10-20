import XCTest
@testable import JamfReports

/// A collect that has not produced today's summary keeps retrying hourly until local midnight.
final class TickSchedulerMissingSummaryTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let label = "com.github.tonyyo11.jamf-reports-community.alpha.collect"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-summary-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private var schedule: Schedule {
        Schedule(
            name: "collect", profile: "alpha", schedule: "Daily 06:00", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
    }

    private func exhausted(startedAt: Date) -> TickState {
        var state = TickState()
        state.lastStarted[label] = startedAt
        state.retryCount[label] = TickScheduler.retryBackoffs.count
        return state
    }

    private func due(_ state: TickState, _ now: Date, missing: Bool) -> [TickScheduler.Reason] {
        TickScheduler.due(
            schedules: [schedule], state: state, runNowLabels: [], now: now,
            summaryMissingToday: { _ in missing }).map(\.reason)
    }

    func testRetriesContinueHourlyAfterTheBackoffsWhileTheSummaryIsMissing() {
        let state = exhausted(startedAt: date(7, 13, 7))
        XCTAssertTrue(due(state, date(7, 13, 50), missing: true).isEmpty, "not before the hour")
        XCTAssertEqual(due(state, date(7, 14, 8), missing: true), [.retry])
        XCTAssertEqual(due(state, date(7, 23, 30), missing: true), [.retry])
    }

    func testRetriesStopOnceTheSummaryExists() {
        XCTAssertTrue(due(exhausted(startedAt: date(7, 13, 7)), date(7, 14, 8), missing: false)
            .isEmpty)
    }

    func testRetriesStopAtLocalMidnight() {
        // The last attempt was late yesterday: today's fire is a fresh run, not a retry.
        let state = exhausted(startedAt: date(7, 23, 30))
        XCTAssertTrue(due(state, date(8, 0, 40), missing: true).isEmpty)
        XCTAssertEqual(due(state, date(8, 6, 1), missing: true), [.fire])
    }

    func testASuccessThatEndsRetriesStopsThemWhateverTheSummary() {
        var state = exhausted(startedAt: date(7, 13, 7))
        state.lastSucceeded[label] = date(7, 13, 7)
        XCTAssertTrue(due(state, date(7, 14, 8), missing: true).isEmpty)
    }

    func testHasSummaryReadsTodaysFileOnly() throws {
        XCTAssertFalse(SummaryJSONParser.hasSummary(profile: "alpha", on: date(7, 9, 0)))
        let dir = try WorkspacePaths.summariesDir(for: "alpha")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("summary_2026-09-07.json"))
        XCTAssertTrue(SummaryJSONParser.hasSummary(profile: "alpha", on: date(7, 9, 0)))
        XCTAssertFalse(SummaryJSONParser.hasSummary(profile: "alpha", on: date(8, 9, 0)))
    }

    func testSchoolWorkspacesNeverCountAsMissingASummary() throws {
        let workspace = root.appendingPathComponent("Jamf-Reports/alpha")
        XCTAssertTrue(summaryMissing(for: schedule, profiles: [], now: date(7, 9, 0)))
        try Data("school_cli:\n  enabled: true\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        XCTAssertFalse(summaryMissing(for: schedule, profiles: [], now: date(7, 9, 0)))
    }
}
