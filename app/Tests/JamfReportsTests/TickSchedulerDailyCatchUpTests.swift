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

    private let label = "com.github.tonyyo11.jamf-reports-community.alpha.collect"

    private func state(
        started: Date, lastTick: Date?, succeeded: Date? = nil
    ) -> TickState {
        var state = TickState()
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
        XCTAssertEqual(reasons(s, off, date(2026, 9, 8, 8, 0)), [.catchUp])
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
        var ran = state(started: date(2026, 9, 8, 8, 0), lastTick: date(2026, 9, 8, 17, 55))
        ran.catchUpStarted[label] = date(2026, 9, 8, 8, 0)
        XCTAssertTrue(reasons(s, ran, date(2026, 9, 8, 18, 1)).isEmpty)
        // A failed early run still gets its retries, measured from that start.
        var failed = ran
        failed.lastSucceeded = [:]
        XCTAssertEqual(reasons(s, failed, date(2026, 9, 8, 18, 1)), [.retry])
    }

    /// Mon 18:00 ran; Tue's 08:00 catch-up fails. Its retries are measured from 08:00, not
    /// from Mon's fire, which the old run had already covered.
    func testAFailedCatchUpRetriesThatMorning() {
        let s = schedule("Daily 18:00")
        var day = state(started: date(2026, 9, 7, 18, 0), lastTick: date(2026, 9, 7, 18, 30))
        XCTAssertEqual(reasons(s, day, date(2026, 9, 8, 8, 0)), [.catchUp])
        day.noteStarted(label, at: date(2026, 9, 8, 8, 0), reason: .catchUp)
        day.lastTick = date(2026, 9, 8, 8, 55)
        XCTAssertEqual(reasons(s, day, date(2026, 9, 8, 9, 0)), [.retry])
    }

    /// A Run now in the morning is not the day's run: the 18:00 fire still runs.
    func testARunNowDoesNotCancelThatEveningsFire() {
        let s = schedule("Daily 18:00")
        var day = state(started: date(2026, 9, 7, 18, 0), lastTick: date(2026, 9, 8, 8, 55))
        day.noteStarted(label, at: date(2026, 9, 8, 9, 0), reason: .runNow)
        day.noteSucceeded(label, startedAt: date(2026, 9, 8, 9, 0))
        day.lastTick = date(2026, 9, 8, 17, 55)
        XCTAssertEqual(reasons(s, day, date(2026, 9, 8, 18, 0)), [.fire])
    }

    /// Five always-on days across the US fall-back change: one run a day, at 18:00.
    func testAnAlwaysOnMacRunsOnceADayAtTheConfiguredTime() {
        var day = state(started: date(2026, 10, 29, 18, 0), lastTick: date(2026, 10, 29, 23, 55))
        let runs = simulate(&day, from: date(2026, 10, 30, 0, 0), to: date(2026, 11, 4, 0, 0))
        XCTAssertEqual(runs.map(\.reason), Array(repeating: .fire, count: 5))
        XCTAssertTrue(runs.allSatisfy { hourMinute($0.at) == [18, 0] }, "\(runs)")
    }

    /// A Run now at 09:00 neither moves the next days' runs to midnight nor skips that day's.
    func testARunNowLeavesEveryLaterDayOnItsFire() {
        var day = state(started: date(2026, 9, 7, 18, 0), lastTick: date(2026, 9, 7, 23, 55))
        let runs = simulate(&day, from: date(2026, 9, 8, 0, 0), to: date(2026, 9, 11, 0, 0),
                            runNow: [date(2026, 9, 8, 9, 0)])
        XCTAssertEqual(runs.map(\.reason), [.runNow, .fire, .fire, .fire])
        XCTAssertEqual(runs.dropFirst().map { hourMinute($0.at) }, [[18, 0], [18, 0], [18, 0]])
    }

    /// The catch-up covers that day's fire, and the next day waits for its own.
    func testAfterACatchUpTheMacRunsAtTheFireAgain() {
        var day = state(started: date(2026, 9, 7, 18, 0), lastTick: date(2026, 9, 7, 18, 30))
        let runs = simulate(&day, from: date(2026, 9, 8, 8, 0), to: date(2026, 9, 10, 0, 0))
        XCTAssertEqual(runs.map(\.reason), [.catchUp, .fire])
        XCTAssertEqual(runs.map { hourMinute($0.at) }, [[8, 0], [18, 0]])
    }

    /// Wakes every `TickLock.wakeInterval` from `start` to `end`; each due run starts and
    /// succeeds at its wake.
    private func simulate(
        _ state: inout TickState, from start: Date, to end: Date, runNow: [Date] = []
    ) -> [(at: Date, reason: TickScheduler.Reason)] {
        let s = schedule("Daily 18:00")
        var runs: [(at: Date, reason: TickScheduler.Reason)] = []
        var now = start
        while now < end {
            let asked = runNow.contains { abs($0.timeIntervalSince(now)) < 1 }
            for run in TickScheduler.due(
                schedules: [s], state: state, runNowLabels: asked ? [label] : [], now: now) {
                state.noteStarted(label, at: now, reason: run.reason)
                state.noteSucceeded(label, startedAt: now)
                runs.append((now, run.reason))
            }
            state.lastTick = now
            now = now.addingTimeInterval(TickLock.wakeInterval)
        }
        return runs
    }

    private func hourMinute(_ date: Date) -> [Int] {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return [c.hour ?? -1, c.minute ?? -1]
    }

    func testWeeklyAndFromCacheSchedulesKeepTheirMeaning() {
        // 2026-09-07 is a Monday; the Mac was off since, and it is Tuesday morning.
        let off = state(started: date(2026, 9, 7, 7, 1), lastTick: date(2026, 9, 7, 8, 0))
        XCTAssertTrue(reasons(schedule("Mon 07:00"), off, date(2026, 9, 8, 8, 0)).isEmpty)
        XCTAssertTrue(reasons(schedule("Day 7 07:00"), off, date(2026, 9, 8, 8, 0)).isEmpty)
        XCTAssertTrue(reasons(schedule("Daily 07:00", mode: .jamfCLIOnly), off,
                              date(2026, 9, 8, 8, 0)).isEmpty)
    }

    /// A GUI collect held the lock 00:00-00:40 on an always-on Mac: the wakes it turned away
    /// were wakes, so 00:40 is no first wake after the Mac was off.
    func testWakesTheLockTurnedAwayAreNotAnOffGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-blocked-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        for minute in [0, 5, 35] {
            TickLock.noteBlocked(url: url, now: date(2026, 9, 8, 0, minute))
        }
        let blocked = try XCTUnwrap(TickLock.takeBlockedSince(url: url))
        XCTAssertEqual(blocked.first, date(2026, 9, 8, 0, 0))
        XCTAssertEqual(blocked.latest, date(2026, 9, 8, 0, 35))
        XCTAssertNil(TickLock.takeBlockedSince(url: url), "taking the stamp clears it")

        var on = state(started: date(2026, 9, 7, 18, 0), lastTick: date(2026, 9, 7, 23, 55))
        on.noteWake(at: blocked.latest)
        XCTAssertTrue(reasons(schedule("Daily 18:00"), on, date(2026, 9, 8, 0, 40)).isEmpty)
        on.noteWake(at: date(2026, 9, 7, 12, 0))
        XCTAssertEqual(on.lastTick, date(2026, 9, 8, 0, 35), "an older wake never moves it back")
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
        saved.catchUpStarted[label] = date(2026, 9, 8, 8, 0)
        try saved.save(url: url)
        XCTAssertEqual(TickState.load(url: url).lastTick, date(2026, 9, 8, 8, 0))
        XCTAssertEqual(TickState.load(url: url).catchUpStarted[label], date(2026, 9, 8, 8, 0))
        try Data(#"{"lastStarted":{}}"#.utf8).write(to: url)
        XCTAssertNil(TickState.load(url: url).lastTick)
        XCTAssertTrue(TickState.load(url: url).catchUpStarted.isEmpty)
    }
}
