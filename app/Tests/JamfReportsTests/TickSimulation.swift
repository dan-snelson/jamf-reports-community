import Foundation
@testable import JamfReports

/// One run a simulated wake started.
struct TickSimRun: Equatable, CustomStringConvertible {
    let at: Date
    let reason: TickScheduler.Reason

    var description: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MM-dd HH:mm:ss"
        return "\(formatter.string(from: at)) \(reason)"
    }
}

/// Drives `TickScheduler.due` and `TickLoop.runDue` wake by wake, in the order `runTick` does:
/// the blocked stamp (a real file), the off gap, the decision, `lastTick`, then the runs. The
/// lock, the state file, the run-now markers and the runs themselves are stand-ins, so a test
/// states the Mac's wakes and gets back every run with its reason and time.
final class TickSimulation {
    var state: TickState
    let schedule: Schedule
    /// Wakes a lock held elsewhere turns away (a GUI collect), half-open.
    var blocked: [Range<Date>] = []
    /// Wakes at which a Run now is queued for `schedule`.
    var runNow: [Date] = []
    /// What a run started at the given time returns. Default: exit 0, complete.
    var outcome: (Date) -> ScheduleRunOutcome = { _ in
        ScheduleRunOutcome(exitCode: 0, incomplete: false)
    }
    /// Whether today's summary is missing at the given wake.
    var summaryMissing: (Date) -> Bool = { _ in true }
    private(set) var markers: Set<String> = []
    private let blockedURL: URL

    init(schedule: Schedule, state: TickState) {
        self.schedule = schedule
        self.state = state
        blockedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-sim-blocked-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: blockedURL) }

    /// A run that fails and that a retry could help.
    static let failure = ScheduleRunOutcome(exitCode: 1, incomplete: false, retryCouldHelp: true)

    /// The agent's wakes, every `TickLock.wakeInterval` from `start` until before `end`.
    static func wakes(from start: Date, to end: Date) -> [Date] {
        stride(from: start.timeIntervalSinceReferenceDate,
               to: end.timeIntervalSinceReferenceDate, by: TickLock.wakeInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    func run(wakes: [Date]) async -> [TickSimRun] {
        var runs: [TickSimRun] = []
        let label = schedule.launchAgentLabel ?? ""
        for now in wakes {
            if runNow.contains(where: { abs($0.timeIntervalSince(now)) < 1 }) {
                markers.insert(label)
            }
            if blocked.contains(where: { $0.contains(now) }) {
                TickLock.noteBlocked(url: blockedURL, now: now)
                continue
            }
            let first = TickLock.takeBlockedSince(url: blockedURL)
            let wasOff = TickScheduler.wasOff(
                lastTick: state.lastTick, firstWake: first ?? now, now: now)
            let due = TickScheduler.due(
                schedules: [schedule], state: state, runNowLabels: markers, now: now,
                nonCatchUpAnchor: first, wasOff: wasOff,
                summaryMissingToday: { [summaryMissing] _ in summaryMissing(now) })
            state.lastTick = now
            _ = await TickLoop.runDue(
                due, state: state, runNowLabels: markers, clock: { now },
                save: { self.state = $0 },
                clearRunNowMarker: { self.markers.remove($0) },
                perform: { run in
                    runs.append(TickSimRun(at: now, reason: run.reason))
                    return self.outcome(now)
                },
                recordFailure: { _, _ in },
                notifyOverdue: {})
        }
        return runs
    }
}
