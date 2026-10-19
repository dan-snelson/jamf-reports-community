import Foundation
import XCTest
@testable import JamfReports

/// No `pro` command runs on a Jamf School profile, and asking jamf-cli which kind a profile
/// is (`config list`) never blocks the main thread.
final class SchoolProCommandRefusalTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ text: String) { lock.withLock { stored.append(text) } }
        var all: [String] { lock.withLock { stored } }
    }

    @MainActor
    func testASchoolProfileIsRefusedWithOneErrorLineAndTheLookupRunsOffMain() async {
        let lines = Lines()
        let onMain = Lines()
        let refusal = await CLIBridge.refusesProCommand(
            profile: "school-a", operation: "Backup",
            onLine: { lines.add($0.text) },
            isSchoolProfile: { _ in
                if Thread.isMainThread { onMain.add("main") }
                return true
            })
        XCTAssertEqual(refusal, "Backup is a Jamf Pro command; 'school-a' is a Jamf School profile")
        XCTAssertEqual(lines.all, ["[error] \(refusal ?? "")"])
        XCTAssertTrue(onMain.all.isEmpty, "the profile lookup ran on the main thread")
    }

    func testAJamfProProfileIsNotRefusedAndLogsNothing() async {
        let lines = Lines()
        let refusal = await CLIBridge.refusesProCommand(
            profile: "pro-a", operation: "Health audit",
            onLine: { lines.add($0.text) }, isSchoolProfile: { _ in false })
        XCTAssertNil(refusal)
        XCTAssertTrue(lines.all.isEmpty)
    }
}
