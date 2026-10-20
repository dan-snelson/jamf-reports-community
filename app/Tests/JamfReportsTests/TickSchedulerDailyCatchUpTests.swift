import XCTest
@testable import JamfReports

/// A daily collect pays a local day when a scheduled run starts on it. It runs at its fire, or
/// on the first wake after the Mac was off or asleep, and its retries stop at local midnight.
/// Each test simulates the Mac's wakes; 2026-09-07 is a Monday.
final class TickSchedulerDailyCatchUpTests: XCTestCase {

    private let label = "com.github.tonyyo11.jamf-reports-community.alpha.collect"

    private func date(
        _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, year: Int = 2026
    ) -> Date {
        var c = DateComponents()
        c.year = year; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c)!
    }

    private func schedule(
        _ cadence: String = "Daily 18:00", mode: Schedule.RunMode = .snapshotOnly
    ) -> Schedule {
        Schedule(
            name: "collect", profile: "alpha", schedule: cadence, cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: label
        )
    }

    /// The last scheduled run started (and succeeded) at `started`; the previous wake was at
    /// `lastTick`.
    private func sim(
        _ cadence: String = "Daily 18:00", mode: Schedule.RunMode = .snapshotOnly,
        started: Date?, lastTick: Date?
    ) -> TickSimulation {
        var state = TickState()
        if let started {
            state.lastStarted[label] = started
            state.lastSucceeded[label] = started
        }
        state.lastTick = lastTick
        return TickSimulation(schedule: schedule(cadence, mode: mode), state: state)
    }

    private func wakes(_ start: Date, _ end: Date) -> [Date] {
        TickSimulation.wakes(from: start, to: end)
    }

    private func run(_ at: Date, _ reason: TickScheduler.Reason) -> TickSimRun {
        TickSimRun(at: at, reason: reason)
    }

    // MARK: - 1-5: when the day's run happens

    /// 1. On 08:00-17:00 Tue-Fri, Monday's 18:00 fire ran: each day runs at 08:00.
    func testAMacOnOfficeHoursRunsEachDayOnItsFirstWake() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 18, 0))
        let days = (8...11).flatMap { wakes(date(9, $0, 8, 0), date(9, $0, 17, 5)) }
        let runs = await s.run(wakes: days)
        XCTAssertEqual(runs, (8...11).map { run(date(9, $0, 8, 0), .catchUp) })
    }

    /// 2. Asleep 23:00-07:00 nightly: Tuesday runs at 07:00, and its 18:00 fire runs nothing.
    func testANightlySleepRunsTheDayOnTheMorningWake() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 18, 0))
        let runs = await s.run(
            wakes: wakes(date(9, 7, 18, 5), date(9, 7, 23, 0))
                + wakes(date(9, 8, 7, 0), date(9, 8, 23, 0)))
        XCTAssertEqual(runs, [run(date(9, 8, 7, 0), .catchUp)])
    }

    /// 3. Always on through the US fall-back change: one run a day, at 18:00.
    func testAnAlwaysOnMacRunsOnceADayAtTheConfiguredTime() async {
        let s = sim(started: date(10, 28, 18, 0), lastTick: date(10, 28, 23, 55))
        let runs = await s.run(wakes: wakes(date(10, 29, 0, 0), date(11, 4, 0, 0)))
        let days = [(10, 29), (10, 30), (10, 31), (11, 1), (11, 2), (11, 3)]
        XCTAssertEqual(runs, days.map { run(date($0.0, $0.1, 18, 0), .fire) })
    }

    /// 4. Off since Monday 17:00. A GUI collect holds the lock 08:00-08:20 on Tuesday: the wakes
    /// it turns away are the first after the gap, so the wake that gets in at 08:20 catches up.
    func testTheFirstWakeAfterTheGapCountsEvenWhenTheLockTurnsItAway() async {
        let s = sim(started: date(9, 7, 8, 0), lastTick: date(9, 7, 16, 55))
        s.blocked = [date(9, 8, 8, 0)..<date(9, 8, 8, 20)]
        let runs = await s.run(
            wakes: [date(9, 8, 8, 0, 30)] + wakes(date(9, 8, 8, 5), date(9, 8, 18, 5)))
        XCTAssertEqual(runs, [run(date(9, 8, 8, 20), .catchUp)])
    }

    /// 5. Always on; a GUI collect holds the lock 00:00-00:40. The wakes it turned away were
    /// wakes, so 00:40 is no first wake after a gap and the day waits for its fire.
    func testWakesTheLockTurnedAwayAreNotAnOffGap() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 23, 55))
        s.blocked = [date(9, 8, 0, 0)..<date(9, 8, 0, 40)]
        let runs = await s.run(wakes: wakes(date(9, 8, 0, 0), date(9, 8, 18, 5)))
        XCTAssertEqual(runs, [run(date(9, 8, 18, 0), .fire)])
    }

    /// The lid closes mid-run at 16:58 and the 17:00 wake is refused; the Mac is off until
    /// Tuesday 08:00 and again at 18:00. The gap after the latest refusal is an off gap, so
    /// Tuesday runs at 08:00.
    func testAGapAfterTheLatestRefusalIsAnOffGap() async {
        let s = sim(started: date(9, 7, 16, 55), lastTick: date(9, 7, 16, 55))
        s.blocked = [date(9, 7, 17, 0)..<date(9, 7, 17, 5)]
        let runs = await s.run(
            wakes: [date(9, 7, 17, 0)] + wakes(date(9, 8, 8, 0), date(9, 8, 17, 5)))
        XCTAssertEqual(runs, [run(date(9, 8, 8, 0), .catchUp)])
    }

    /// A tick run holds the lock through a night's sleep: it turns away the 23:00 wake and,
    /// once the Mac wakes and the run carries on, the 08:00 and 08:05 wakes. The night between
    /// two refusals is an off gap, so Tuesday runs when the lock frees; its 18:00 is off.
    func testANightBetweenTwoRefusalsIsAnOffGap() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 22, 55))
        s.blocked = [date(9, 7, 23, 0)..<date(9, 8, 8, 10)]
        let runs = await s.run(
            wakes: [date(9, 7, 23, 0)] + wakes(date(9, 8, 8, 0), date(9, 8, 17, 5)))
        XCTAssertEqual(runs, [run(date(9, 8, 8, 10), .catchUp)])
    }

    /// A refusal at 22:00 survives the night. A backup's 07:00 fire is measured from the first
    /// refusal after the night, not from 22:00: it runs at 07:40 behind morning refusals that
    /// began 06:55, but not at 08:30 behind ones that began 08:00, nor at a 09:00 first wake.
    func testAnEveningRefusalDoesNotStretchAMorningBackupsWindow() async {
        func runs(_ morning: [Date], blockedUntil: Date?) async -> [TickSimRun] {
            let s = sim("Daily 07:00", mode: .backup, started: date(9, 7, 7, 0),
                        lastTick: date(9, 7, 21, 55))
            s.blocked = [date(9, 7, 22, 0)..<date(9, 7, 22, 5)]
            if let start = morning.first, let blockedUntil {
                s.blocked.append(start..<blockedUntil)
            }
            return await s.run(wakes: [date(9, 7, 22, 0)] + morning)
        }
        let late = await runs(wakes(date(9, 8, 9, 0), date(9, 8, 17, 5)), blockedUntil: nil)
        XCTAssertEqual(late, [])
        let behind = await runs(
            wakes(date(9, 8, 8, 0), date(9, 8, 17, 5)), blockedUntil: date(9, 8, 8, 30))
        XCTAssertEqual(behind, [])
        let inWindow = await runs(
            wakes(date(9, 8, 6, 55), date(9, 8, 17, 5)), blockedUntil: date(9, 8, 7, 40))
        XCTAssertEqual(inWindow, [run(date(9, 8, 7, 40), .fire)])
    }

    // MARK: - 6-7, 11: Run now

    /// 6. Off since Monday 17:00; a Run now at 09:00 is Tuesday's first wake. The catch-up it
    /// coincides with runs (and clears the marker); its failure retries 10:00, 12:00, 16:00,
    /// then hourly to 23:00 while the summary is missing, and never past midnight.
    func testARunNowThatIsTheFirstWakeRunsTheCatchUpAndItsRetries() async {
        let s = sim(started: date(9, 7, 8, 0), lastTick: date(9, 7, 16, 55))
        s.runNow = [date(9, 8, 9, 0)]
        s.outcome = { _ in TickSimulation.failure }
        let runs = await s.run(wakes: wakes(date(9, 8, 9, 0), date(9, 9, 0, 35)))
        XCTAssertEqual(runs, [run(date(9, 8, 9, 0), .catchUp)]
            + [10, 12, 16, 17, 18, 19, 20, 21, 22, 23].map { run(date(9, 8, $0, 0), .retry) })
        XCTAssertTrue(s.markers.isEmpty, "the catch-up honoured the Run now")
    }

    /// 7. Always on; a Run now at 09:00 runs as itself and pays nothing: 18:00 still runs.
    func testARunNowLeavesTheDayToItsFire() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 23, 55))
        s.runNow = [date(9, 8, 9, 0)]
        let runs = await s.run(wakes: wakes(date(9, 8, 0, 0), date(9, 10, 0, 0)))
        XCTAssertEqual(runs, [
            run(date(9, 8, 9, 0), .runNow), run(date(9, 8, 18, 0), .fire),
            run(date(9, 9, 18, 0), .fire),
        ])
        XCTAssertTrue(s.markers.isEmpty)
    }

    /// 11. A weekly fire missed; a Run now at 09:00 is the first wake. The fire runs (the
    /// marker is cleared) and its failure keeps the three backoffs.
    func testARunNowOnAMissedWeeklyFireRunsTheFire() async {
        let s = sim("Mon 07:00", started: date(8, 31, 7, 0), lastTick: date(9, 6, 20, 0))
        s.runNow = [date(9, 7, 9, 0)]
        s.outcome = { _ in TickSimulation.failure }
        s.summaryMissing = { _ in false }
        let runs = await s.run(wakes: wakes(date(9, 7, 9, 0), date(9, 7, 17, 5)))
        XCTAssertEqual(runs, [run(date(9, 7, 9, 0), .fire)]
            + [10, 12, 16].map { run(date(9, 7, $0, 0), .retry) })
        XCTAssertTrue(s.markers.isEmpty)
    }

    // MARK: - 8-10: retries

    /// 8. Tuesday's 08:00 catch-up fails and the Mac is on until 17:00: retries 09:00, 11:00,
    /// 15:00, then 16:00 and 17:00 while the summary is missing and a retry could help.
    func testAFailedCatchUpRetriesThroughTheDay() async {
        func runs(summaryMissing: Bool, couldHelp: Bool) async -> [TickSimRun] {
            let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 18, 0))
            s.outcome = { _ in
                ScheduleRunOutcome(exitCode: 1, incomplete: false, retryCouldHelp: couldHelp)
            }
            s.summaryMissing = { _ in summaryMissing }
            return await s.run(wakes: wakes(date(9, 8, 8, 0), date(9, 8, 17, 5)))
        }
        let backoffs = [run(date(9, 8, 8, 0), .catchUp)]
            + [9, 11, 15].map { run(date(9, 8, $0, 0), .retry) }
        let hourly = [16, 17].map { run(date(9, 8, $0, 0), .retry) }
        let missingAndHelps = await runs(summaryMissing: true, couldHelp: true)
        XCTAssertEqual(missingAndHelps, backoffs + hourly)
        let present = await runs(summaryMissing: false, couldHelp: true)
        XCTAssertEqual(present, backoffs)
        let wouldRepeat = await runs(summaryMissing: true, couldHelp: false)
        XCTAssertEqual(wouldRepeat, backoffs)
    }

    /// 9. Tuesday's 08:00 catch-up succeeds on a Mac that stays on: Tuesday 18:00 and Wednesday
    /// midnight run nothing, Wednesday runs at its fire.
    func testASuccessfulCatchUpPaysTheDay() async {
        let s = sim(started: date(9, 7, 18, 0), lastTick: date(9, 7, 18, 0))
        let runs = await s.run(wakes: wakes(date(9, 8, 8, 0), date(9, 10, 0, 0)))
        XCTAssertEqual(runs, [run(date(9, 8, 8, 0), .catchUp), run(date(9, 9, 18, 0), .fire)])
    }

    /// 10. "Daily 23:30" fails Tuesday: its first backoff would be Wednesday 00:30, past
    /// midnight, so nothing runs until Wednesday's fire.
    func testADailyRetryNeverCrossesMidnight() async {
        let s = sim("Daily 23:30", started: date(9, 7, 23, 30), lastTick: date(9, 7, 23, 55))
        let failing = date(9, 8, 23, 30)
        s.outcome = { $0 == failing ? TickSimulation.failure
            : ScheduleRunOutcome(exitCode: 0, incomplete: false) }
        let runs = await s.run(wakes: wakes(date(9, 8, 0, 0), date(9, 10, 0, 0)))
        XCTAssertEqual(runs, [run(failing, .fire), run(date(9, 9, 23, 30), .fire)])
    }

    /// A weekly schedule failing at 23:00 keeps its three backoffs past midnight.
    func testAWeeklyRetryStillCrossesMidnight() async {
        let s = sim("Mon 23:00", started: date(8, 31, 23, 0), lastTick: date(9, 7, 22, 55))
        s.outcome = { _ in TickSimulation.failure }
        s.summaryMissing = { _ in false }
        let runs = await s.run(wakes: wakes(date(9, 7, 22, 55), date(9, 8, 8, 0)))
        XCTAssertEqual(runs, [run(date(9, 7, 23, 0), .fire)]
            + [0, 2, 6].map { run(date(9, 8, $0, 0), .retry) })
    }

    // MARK: - 12: weekly, monthly and non-collect schedules keep their rule

    /// 12. Off overnight, on 08:00-17:00. A weekday schedule catches up the fire it missed the
    /// next morning; a monthly one on the day; a run from cache and a backup only within 15
    /// minutes of their fire, and neither retries.
    func testNonDailyAndNonCollectSchedulesKeepTheirRule() async {
        let weekdays = sim("Weekdays 18:00", started: date(9, 7, 18, 0),
                           lastTick: date(9, 7, 18, 0))
        let weekdayRuns = await weekdays.run(
            wakes: wakes(date(9, 8, 8, 0), date(9, 8, 17, 5))
                + wakes(date(9, 9, 8, 0), date(9, 9, 17, 5)))
        XCTAssertEqual(weekdayRuns, [run(date(9, 9, 8, 0), .fire)])

        let monthly = sim("Day 15 07:00", started: date(8, 15, 7, 0),
                          lastTick: date(9, 14, 17, 0))
        let monthlyRuns = await monthly.run(
            wakes: wakes(date(9, 15, 8, 0), date(9, 15, 17, 5))
                + wakes(date(9, 16, 8, 0), date(9, 16, 17, 5)))
        XCTAssertEqual(monthlyRuns, [run(date(9, 15, 8, 0), .fire)])

        let fromCache = sim("Daily 07:00", mode: .jamfCLIOnly, started: date(9, 7, 7, 0),
                            lastTick: date(9, 7, 17, 0))
        fromCache.outcome = { _ in TickSimulation.failure }
        let cacheRuns = await fromCache.run(
            wakes: wakes(date(9, 8, 8, 0), date(9, 8, 17, 5))
                + wakes(date(9, 9, 7, 5), date(9, 9, 17, 5)))
        XCTAssertEqual(cacheRuns, [run(date(9, 9, 7, 5), .fire)])

        let backup = sim("Mon 07:00", mode: .backup, started: date(8, 31, 7, 0),
                         lastTick: date(9, 6, 17, 0))
        backup.outcome = { _ in TickSimulation.failure }
        let backupRuns = await backup.run(
            wakes: wakes(date(9, 7, 8, 0), date(9, 7, 17, 5))
                + wakes(date(9, 14, 7, 10), date(9, 14, 17, 5)))
        XCTAssertEqual(backupRuns, [run(date(9, 14, 7, 10), .fire)])
    }

    // MARK: - 13-14: upgrade and clock skew

    /// 13. A state file from before `lastTick` reads as no gap: a paid Monday waits for
    /// Tuesday's fire, an unpaid one runs on the first wake.
    func testAStateWithoutALastTickReadsAsNoGap() async {
        let paid = sim(started: date(9, 7, 8, 0), lastTick: nil)
        let paidRuns = await paid.run(wakes: wakes(date(9, 8, 8, 0), date(9, 8, 18, 5)))
        XCTAssertEqual(paidRuns, [run(date(9, 8, 18, 0), .fire)])

        let missed = sim(started: date(9, 6, 18, 0), lastTick: nil)
        let missedRuns = await missed.run(wakes: wakes(date(9, 8, 8, 0), date(9, 8, 18, 5)))
        XCTAssertEqual(missedRuns, [run(date(9, 8, 8, 0), .fire)])
    }

    /// 14. A start and a wake stamped 30 days ahead (a clock set ahead once) read as absent.
    func testStampsFarAheadReadAsAbsent() async {
        let now = date(9, 8, 18, 0)
        let ahead = now.addingTimeInterval(30 * 86_400)
        let s = sim(started: ahead, lastTick: ahead)
        let runs = await s.run(wakes: wakes(now, date(9, 9, 18, 5)))
        XCTAssertEqual(runs, [run(now, .fire), run(date(9, 9, 18, 0), .fire)])
    }

    // MARK: - The off gap and the blocked stamp

    func testTheOffGapIsMeasuredToTheFirstWakeSinceTheLastTick() {
        let last = date(9, 8, 8, 0)
        func off(
            _ lastTick: Date?, _ first: Date?, _ latest: Date?, _ now: Date,
            afterGap: Date? = nil
        ) -> Bool {
            let refusals = first.map { ($0, latest ?? $0, afterGap) }
            return TickScheduler.wasOff(lastTick: lastTick, refusals: refusals, now: now)
        }
        XCTAssertFalse(off(nil, nil, nil, date(9, 8, 9, 0)))
        XCTAssertFalse(off(last, nil, nil, date(9, 8, 8, 15)), "15 minutes is no gap")
        XCTAssertTrue(off(last, nil, nil, date(9, 8, 8, 16)))
        XCTAssertFalse(off(last, date(9, 8, 8, 5), date(9, 8, 8, 55), date(9, 8, 9, 0)),
                       "turned-away wakes at 08:05-08:55 were wakes")
        XCTAssertTrue(off(last, date(9, 8, 8, 5), date(9, 8, 8, 5), date(9, 8, 9, 0)),
                      "nothing woke between 08:05 and 09:00")
        XCTAssertTrue(off(nil, date(9, 8, 8, 5), date(9, 8, 8, 5), date(9, 8, 9, 0)),
                      "a gap after a refusal needs no lastTick")
        XCTAssertTrue(off(last, date(9, 8, 8, 5), date(9, 8, 8, 55), date(9, 8, 9, 0),
                          afterGap: date(9, 8, 8, 40)), "a gap between two refusals")
        XCTAssertFalse(off(last, date(9, 8, 8, 5), date(9, 8, 8, 55), date(9, 8, 9, 0),
                           afterGap: date(9, 8, 9, 30)), "a gap stamped ahead reads as absent")
        XCTAssertFalse(off(date(9, 8, 9, 1), nil, nil, date(9, 8, 9, 0)),
                       "a lastTick ahead of now is no gap")
        XCTAssertFalse(off(last, date(9, 8, 9, 1), date(9, 8, 9, 1), date(9, 8, 8, 10)),
                       "refusals ahead of now read as absent")
    }

    func testTheBlockedStampKeepsTheFirstAndTheLatestRefusal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-blocked-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        for minute in [0, 5, 35] {
            TickLock.noteBlocked(url: url, now: date(9, 8, 0, minute))
        }
        let blocked = try XCTUnwrap(TickLock.takeBlockedSince(url: url))
        XCTAssertEqual(blocked.first, date(9, 8, 0, 0))
        XCTAssertEqual(blocked.latest, date(9, 8, 0, 35))
        XCTAssertNil(TickLock.takeBlockedSince(url: url), "taking the stamp clears it")
        XCTAssertEqual(blocked.afterGap, date(9, 8, 0, 35), "00:05 to 00:35 is a gap")
        for minute in [0, 5, 10] {
            TickLock.noteBlocked(url: url, now: date(9, 8, 0, minute))
        }
        XCTAssertNil(try XCTUnwrap(TickLock.takeBlockedSince(url: url)).afterGap,
                     "five-minute steps are no gap")
        for (h, m) in [(0, 0), (0, 5), (0, 30), (0, 35), (1, 30)] {
            TickLock.noteBlocked(url: url, now: date(9, 8, h, m))
        }
        let gapped = try XCTUnwrap(TickLock.takeBlockedSince(url: url))
        XCTAssertEqual(gapped.first, date(9, 8, 0, 0))
        XCTAssertEqual(gapped.latest, date(9, 8, 1, 30))
        XCTAssertEqual(gapped.afterGap, date(9, 8, 1, 30), "the first refusal after the last gap")
        // An earlier build's one-line stamp is both, with no gap.
        try Data(ISO8601DateFormatter().string(from: date(9, 8, 0, 0)).utf8).write(to: url)
        let old = try XCTUnwrap(TickLock.takeBlockedSince(url: url))
        XCTAssertEqual(old.latest, date(9, 8, 0, 0))
        XCTAssertNil(old.afterGap)
    }

    // MARK: - State file

    /// A file an earlier 2.11 build wrote keeps its stamps; its `catchUpStarted` is dropped.
    func testOlderStateFilesDecode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let stamp = ISO8601DateFormatter().string(from: date(9, 8, 8, 0))
        try Data(#"""
            {"lastStarted":{"\#(label)":"\#(stamp)"},"lastTick":"\#(stamp)",
             "catchUpStarted":{"\#(label)":"\#(stamp)"}}
            """#.utf8).write(to: url)
        let loaded = TickState.load(url: url)
        XCTAssertEqual(loaded.lastStarted[label], date(9, 8, 8, 0))
        XCTAssertEqual(loaded.lastTick, date(9, 8, 8, 0))
        XCTAssertNil(loaded.retryCount[label])
        try loaded.save(url: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("catchUpStarted"), text)
    }
}
