import Foundation
import XCTest
@testable import JamfReports

final class ValidationVerdictTests: XCTestCase {
    // Shape of `jamf-cli config validate --output json` (internal/commands/config.go, 1.33.0).
    private func json(_ rows: [(String, String, String, String?)]) -> Data {
        let objects = rows.map { scope, name, status, message -> [String: String] in
            var row = ["scope": scope, "name": name, "status": status]
            if let message { row["message"] = message }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: objects)) ?? Data()
    }

    func testAnotherProfilesFailurePassesThisProfile() {
        let out = json([
            ("config", "file-exists", "pass", nil),
            ("pro", "auth-method", "pass", nil),
            ("school", "auth-method", "fail", "invalid \"apikey\""),
        ])
        let verdict = CLIBridge.validationVerdict(stdout: out, exitCode: 1, profile: "pro")
        XCTAssertEqual(verdict.exit, 0)
        XCTAssertTrue(verdict.failures.isEmpty)
    }

    func testThisProfilesFailureFailsWithTheCLIExitCode() {
        let out = json([("pro", "client-secret", "fail", "missing")])
        let verdict = CLIBridge.validationVerdict(stdout: out, exitCode: 1, profile: "pro")
        XCTAssertEqual(verdict.exit, 1)
        XCTAssertEqual(verdict.failures, ["pro client-secret failed: missing"])
    }

    func testAConfigScopeFailureFailsEveryProfile() {
        let out = json([("config", "valid-yaml", "fail", "bad")])
        XCTAssertEqual(CLIBridge.validationVerdict(stdout: out, exitCode: 1, profile: "pro").exit, 1)
    }

    func testAFailureWithExitZeroStillFails() {
        let out = json([("pro", "url", "fail", nil)])
        let verdict = CLIBridge.validationVerdict(stdout: out, exitCode: 0, profile: "pro")
        XCTAssertEqual(verdict.exit, 1)
        XCTAssertEqual(verdict.failures, ["pro url failed"])
    }

    func testAProfileWithNoRowsFails() {
        let out = json([("config", "file-exists", "pass", nil), ("other", "url", "pass", nil)])
        let verdict = CLIBridge.validationVerdict(stdout: out, exitCode: 0, profile: "pro")
        XCTAssertEqual(verdict.exit, 1)
        XCTAssertEqual(verdict.failures, ["pro not found in jamf-cli's config"])
    }

    func testUnparseableOutputKeepsTheExitCode() {
        let junk = Data("not json".utf8)
        XCTAssertEqual(CLIBridge.validationVerdict(stdout: junk, exitCode: 7, profile: "pro").exit, 7)
        XCTAssertEqual(CLIBridge.validationVerdict(stdout: junk, exitCode: 0, profile: "pro").exit, 0)
        XCTAssertEqual(CLIBridge.validationVerdict(stdout: Data(), exitCode: 1, profile: "pro").exit, 1)
    }
}
