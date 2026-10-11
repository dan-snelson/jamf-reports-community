import Foundation
import XCTest
@testable import JamfReports

@MainActor
final class DefaultCLIExecutorTimeoutTests: XCTestCase {

    private func stubURL() throws -> URL {
        let dir = try SleepingCLIStub.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try SleepingCLIStub.make(in: dir)
    }

    func test_defaultTimeoutIsSixtySeconds() {
        XCTAssertEqual(DefaultCLIExecutor.defaultTimeout, 60)
        XCTAssertEqual(DefaultCLIExecutor(bridge: CLIBridge()).timeout, 60)
    }

    /// A stalled command fails with the executor's usual error shape and names the limit.
    func test_stalledCommandThrowsNonZeroExitNamingTheTimeout() async throws {
        let executor = DefaultCLIExecutor(
            bridge: CLIBridge(), timeout: 1, _testExecutable: try stubURL()
        )
        let started = Date()
        do {
            _ = try await executor.execute(.proHelp)
            XCTFail("a stalled command must throw")
        } catch let CLIExecutorError.nonZeroExit(code, stderr) {
            XCTAssertEqual(code, CLIBridge.exitCodeTimedOut)
            XCTAssertTrue(stderr.contains("did not answer within 1 s"), "stderr: \(stderr)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    /// The per-call limit wins over the executor's own.
    func test_perCallTimeoutOverridesTheExecutorDefault() async throws {
        let executor = DefaultCLIExecutor(bridge: CLIBridge(), _testExecutable: try stubURL())
        let started = Date()
        do {
            _ = try await executor.execute(.configList, timeout: 1)
            XCTFail("a stalled command must throw")
        } catch let CLIExecutorError.nonZeroExit(code, stderr) {
            XCTAssertEqual(code, CLIBridge.exitCodeTimedOut)
            XCTAssertTrue(stderr.contains("within 1 s"), "stderr: \(stderr)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "returned at the per-call limit, not the 60 s default")
    }
}
