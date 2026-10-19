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
}
