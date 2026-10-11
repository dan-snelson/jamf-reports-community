import XCTest
@testable import JamfReports

/// With `automation` refused, the hourly self-remediation marker can never be stamped, so the
/// re-collect must not run on every check.
@MainActor
final class RefusedAutomationRemediationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testSelfRemediationDoesNotRunWhenItsMarkerCannotBeWritten() async throws {
        let fm = FileManager.default
        let profile = "refused"
        let root = fm.temporaryDirectory
            .appendingPathComponent("jrc-refused-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "".write(to: workspace.appendingPathComponent("config.yaml"),
                     atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: workspace.appendingPathComponent("automation"), withDestinationURL: elsewhere)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let store = WorkspaceStore(demoMode: false, tickerRegistrar: StubTickerRegistrar())
        store.profile = profile
        _ = useTemporaryTickLock()
        AutomationHealthModel.shared.freshnessIssues = [DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: .stale,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            consecutiveFailures: 0, lastFailure: nil)]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }

        let runs = Counter()
        let collect: WorkspaceStore.RemediationCollector = { _, _, _ in runs.bump() }
        for _ in 0..<3 {
            let attempted = await store.remediateStaleDataIfNeeded(collect: collect)
            XCTAssertFalse(attempted)
        }
        XCTAssertEqual(runs.value, 0)
        XCTAssertTrue(((try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? []).isEmpty)
    }
}
