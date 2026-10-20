import XCTest
@testable import JamfReports

/// School and Protect collects tell the truth about launch failures and a refused state folder,
/// as the Jamf Pro collect does.
final class SchoolProtectCollectHonestyTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private let profile = "school-honesty"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SPHonesty-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        // Not named `jamf-cli`: `CLIBridge.codesignGate` keys on that filename.
        bin = root.appendingPathComponent("stub-cli")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func installStub(executable: Bool, exitCode: Int = 1) throws {
        let body = executable ? "#!/bin/sh\nexit \(exitCode)\n" : "not an executable\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: bin.path)
    }

    func testSchoolRunWhereEveryKindFailsToLaunchIsADeadCollect() async throws {
        try installStub(executable: false)
        let stub: URL = bin
        do {
            try await ReportEngine.schoolCollect(
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("a School run that launched nothing must not succeed")
        } catch ReportEngineError.collectDead(_, let failedCount, _) {
            XCTAssertGreaterThan(failedCount, 0)
        }
    }
}
