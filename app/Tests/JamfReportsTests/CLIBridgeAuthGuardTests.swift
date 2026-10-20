import Foundation
import XCTest
@testable import JamfReports

/// The exit-code constants the auth guard and its callers branch on, and the apikey bypass
/// (`CLIBridge.shouldSkipAuthProbe`). The guard calls `pro auth token`; the timeout test injects a
/// sleeping stub, and no test runs a real jamf-cli.
@MainActor
final class CLIBridgeAuthGuardTests: XCTestCase {

    // MARK: - Constants

    func test_exitCodeUnauthorized_isThree() {
        // jamf-cli maps HTTP 401 → exit 3. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUnauthorized, 3)
    }

    func test_exitCodePermissionDenied_isFive() {
        // jamf-cli maps HTTP 403 → exit 5.
        XCTAssertEqual(CLIBridge.exitCodePermissionDenied, 5)
    }

    func test_exitCodeRateLimited_isSix() {
        // jamf-cli maps HTTP 429 → exit 6.
        XCTAssertEqual(CLIBridge.exitCodeRateLimited, 6)
    }

    func test_exitCodeUsage_isTwo() {
        // jamf-cli maps bad flags / missing args → exit 2. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUsage, 2)
    }

    func test_exitCodeNotFound_isFour() {
        // jamf-cli maps HTTP 404 → exit 4. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeNotFound, 4)
    }

    // MARK: - shouldSkipAuthProbe unit tests

    func test_shouldSkipAuthProbe_trueForAPIKey() {
        XCTAssertTrue(CLIBridge.shouldSkipAuthProbe(for: "apikey"))
    }

    func test_shouldSkipAuthProbe_falseForBearer() {
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: "bearer"))
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: ""))
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: "APIKEY")) // case-sensitive
    }

    // MARK: - Probe timeout

    /// A probe that gets no answer is not a rejection: one warn line, no re-authenticate error,
    /// and the guard lets the command run.
    func test_authGuard_probeTimeoutWarnsOnceAndProceeds() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try SleepingCLIStub.make(in: dir)
        let collector = GuardLineCollector()
        let started = Date()

        let proceed = await CLIBridge().authGuard(
            profile: "timeout-probe", probeTimeout: 0.5, _testExecutable: stub
        ) { collector.append($0) }

        XCTAssertTrue(proceed, "a probe that timed out must not block the command")
        let texts = collector.texts()
        XCTAssertEqual(texts.filter { $0.hasPrefix("[warn] auth check timed out") }.count, 1,
                       "expected exactly one timeout warn line; got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("[error]") || $0.contains("re-authenticate") },
                       "a timeout must not read as rejected credentials; got: \(texts)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}

extension CLIBridgeAuthGuardTests {
    /// `pro auth token` is meaningless on a profile of another product: the guard passes it
    /// without running the probe (a sleeping stub would time out and warn if it ran), while a
    /// Jamf Pro profile is still probed.
    func test_authGuard_skipsTheProbeForAnotherProductOnly() async throws {
        let dir = try SleepingCLIStub.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir); ProfileAuthMethod.invalidateCache() }
        let stub = try SleepingCLIStub.make(in: dir)
        ProfileAuthMethod.invalidateCache()
        try ProductGuardSeed.seed(profile: "guard-protect", product: "protect", in: dir)
        try ProductGuardSeed.seed(profile: "guard-pro", product: "pro", in: dir)

        let skipped = ProductGuardLines()
        let passed = await CLIBridge().authGuard(
            profile: "guard-protect", probeTimeout: 0.5, _testExecutable: stub, onLine: skipped.add)
        XCTAssertTrue(passed)
        XCTAssertTrue(skipped.all.isEmpty, "\(skipped.all)")
        let status = await CLIBridge().tokenStatus(for: "guard-protect")
        XCTAssertNil(status)

        let probed = ProductGuardLines()
        _ = await CLIBridge().authGuard(
            profile: "guard-pro", probeTimeout: 0.5, _testExecutable: stub, onLine: probed.add)
        XCTAssertEqual(probed.all.filter { $0.hasPrefix("[warn] auth check timed out") }.count, 1)
    }
}

private final class GuardLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: CLIBridge.LogLine) { lock.lock(); lines.append(line.text); lock.unlock() }
    func texts() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
