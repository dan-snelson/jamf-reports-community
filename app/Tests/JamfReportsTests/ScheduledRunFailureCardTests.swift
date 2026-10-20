import XCTest
@testable import JamfReports

/// Failures a scheduled run ends with before any collect still page the notify webhook.
final class ScheduledRunFailureCardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var savedProbe: (@Sendable () -> String?)!
    private let profile = "card"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-card-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        savedProbe = JamfCLIInstaller.installedVersionProbe
        WebhookCapture.start()
        try writeConfig(
            "notify:\n  enabled: true\n  provider: teams\n  url: \"\(WebhookCapture.webhookURL)\"\n")
    }

    override func tearDownWithError() throws {
        JamfCLIInstaller.installedVersionProbe = savedProbe
        WebhookCapture.stop()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfig(_ yaml: String) throws {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "card", profile: profile, schedule: "manual", cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.card.\(mode.rawValue)")
    }

    func testAJamfCLIBelowTheRunnableFloorPostsAFailureCard() async {
        JamfCLIInstaller.installedVersionProbe = { "1.10.0" }
        let outcome = await runSchedule(schedule(.snapshotOnly), verbose: false)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        XCTAssertTrue(WebhookCapture.posted.first?.contains("Failed") == true)
    }

    // MARK: - Refused runs

    private func refusedSchedule() -> Schedule {
        Schedule(
            name: "refused", profile: profile, schedule: "manual", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.r\(UUID().uuidString.prefix(8))")
    }

    func testARefusedRunPostsOneCardADayAndWritesNothingInTheWorkspace() async throws {
        try ProductGuardSeed.seed(profile: profile, product: "protect", in: root)
        let schedule = refusedSchedule()
        for _ in 0..<3 {
            let outcome = await runSchedule(schedule, verbose: false)
            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertTrue(outcome.endsRetries)
        }
        XCTAssertEqual(WebhookCapture.posted.count, 1, "once a day, not once a wake")
        XCTAssertTrue(WebhookCapture.posted.first?.contains("Failed") == true)
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("automation").path))
    }

    func testARefusedRunPostsAgainTheNextDayAndPerSchedule() async throws {
        let config = try ConfigLoader.load(from: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml"))
        let state = root.appendingPathComponent("refused-state")
        let today = Date()
        for (key, day) in [("a", today), ("a", today), ("b", today),
                           ("a", today.addingTimeInterval(86_400))] {
            await ScheduledRunSignals.notifyRefusedRun(
                config: config, profile: profile, mode: .snapshotOnly, scheduleKey: key,
                refusal: "refused", stateRoot: state, now: day)
        }
        XCTAssertEqual(WebhookCapture.posted.count, 3)
    }
}
