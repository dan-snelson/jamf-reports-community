import XCTest
@testable import JamfReports

/// A daily schedule runs once on each local day the Mac is awake for a wake, even when the Mac
/// is off at the schedule's own time.
final class TickSchedulerDailyCatchUpTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(
        _ cadence: String, mode: Schedule.RunMode = .snapshotOnly
    ) -> Schedule {
        Schedule(
            name: "collect", profile: "alpha", schedule: cadence, cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.alpha.collect"
        )
    }

    private func state(
        started: Date, lastTick: Date?, succeeded: Date? = nil
    ) -> TickState {
        var state = TickState()
        let label = "com.github.tonyyo11.jamf-reports-community.alpha.collect"
        state.lastStarted[label] = started
        state.lastSucceeded[label] = succeeded ?? started
        state.lastTick = lastTick
        return state
    }

    private func reasons(_ s: Schedule, _ state: TickState, _ now: Date) -> [TickScheduler.Reason] {
        TickScheduler.due(schedules: [s], state: state, runNowLabels: [], now: now).map(\.reason)
    }

    /// Mon 18:00 fire ran; the Mac is on Tue 08:00-17:00 only. Today's fire is later, but the
    /// Mac will be off by then.
    func testFirstWakeAfterTheMacWasOffRunsADailyScheduleEarly() {
        let s = schedule("Daily 18:00")
        let off = state(started: date(2026, 9, 7, 18, 1), lastTick: date(2026, 9, 7, 18, 30))
        XCTAssertEqual(reasons(s, off, date(2026, 9, 8, 8, 0)), [.fire])
    }

    func testAnAlwaysOnMacWaitsForTheFireInsteadOfRunningAtMidnight() {
        let s = schedule("Daily 18:00")
        let on = state(started: date(2026, 9, 7, 18, 1), lastTick: date(2026, 9, 7, 23, 55))
        XCTAssertTrue(reasons(s, on, date(2026, 9, 8, 0, 0)).isEmpty)
        let morning = state(started: date(2026, 9, 7, 18, 1), lastTick: date(2026, 9, 8, 7, 55))
        XCTAssertTrue(reasons(s, morning, date(2026, 9, 8, 8, 0)).isEmpty)
    }

    func testAnEarlyRunIsTheDaysRunAndTheFireDoesNotRunItAgain() {
        let s = schedule("Daily 18:00")
        let ran = state(started: date(2026, 9, 8, 8, 0), lastTick: date(2026, 9, 8, 17, 55))
        XCTAssertTrue(reasons(s, ran, date(2026, 9, 8, 18, 1)).isEmpty)
        // A failed early run still gets its retries, measured from that start.
        var failed = ran
        failed.lastSucceeded = [:]
        XCTAssertEqual(reasons(s, failed, date(2026, 9, 8, 18, 1)), [.retry])
    }

    func testWeeklyAndFromCacheSchedulesKeepTheirMeaning() {
        // 2026-09-07 is a Monday; the Mac was off since, and it is Tuesday morning.
        let off = state(started: date(2026, 9, 7, 7, 1), lastTick: date(2026, 9, 7, 8, 0))
        XCTAssertTrue(reasons(schedule("Mon 07:00"), off, date(2026, 9, 8, 8, 0)).isEmpty)
        XCTAssertTrue(reasons(schedule("Day 7 07:00"), off, date(2026, 9, 8, 8, 0)).isEmpty)
        XCTAssertTrue(reasons(schedule("Daily 07:00", mode: .jamfCLIOnly), off,
                              date(2026, 9, 8, 8, 0)).isEmpty)
    }

    func testNoRecordedWakeMeansNoEarlyRun() {
        let s = schedule("Daily 18:00")
        let unknown = state(started: date(2026, 9, 7, 18, 1), lastTick: nil)
        XCTAssertTrue(reasons(s, unknown, date(2026, 9, 8, 8, 0)).isEmpty)
    }

    func testLastTickRoundTripsAndOlderFilesDecode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var saved = TickState()
        saved.lastTick = date(2026, 9, 8, 8, 0)
        try saved.save(url: url)
        XCTAssertEqual(TickState.load(url: url).lastTick, date(2026, 9, 8, 8, 0))
        try Data(#"{"lastStarted":{}}"#.utf8).write(to: url)
        XCTAssertNil(TickState.load(url: url).lastTick)
    }
}
