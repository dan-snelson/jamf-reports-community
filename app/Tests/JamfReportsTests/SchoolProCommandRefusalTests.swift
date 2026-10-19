import Foundation
import XCTest
@testable import JamfReports

/// No `pro` command runs on a profile of another product, and asking jamf-cli which kind a profile
/// is (`config list`) never blocks the main thread.
final class SchoolProCommandRefusalTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ text: String) { lock.withLock { stored.append(text) } }
        var all: [String] { lock.withLock { stored } }
    }

    private func resolved(
        _ product: JamfCLIProduct, org: Bool = false
    ) -> @Sendable (String) -> ProfileAuthMethod.Resolved? {
        { _ in
            if Thread.isMainThread { XCTFail("the profile lookup ran on the main thread") }
            return .init(
                authMethod: "oauth2", isTenantLevel: false, isOrganizationLevel: org,
                product: product)
        }
    }

    @MainActor
    func testAnotherProductIsRefusedWithOneErrorLineAndTheLookupRunsOffMain() async {
        let cases: [(JamfCLIProduct, String)] = [
            (.school, "Jamf School"), (.protect, "Jamf Protect"),
            (.securityCloud, "Jamf Security Cloud"),
        ]
        for (product, name) in cases {
            let lines = Lines()
            let refusal = await CLIBridge.refusesProCommand(
                profile: "other", operation: "Backup", onLine: { lines.add($0.text) },
                resolved: resolved(product))
            XCTAssertEqual(refusal, "Backup is a Jamf Pro command; 'other' is a \(name) profile")
            XCTAssertEqual(lines.all, ["[error] \(refusal ?? "")"])
        }
    }

    func testAnOrganizationLevelProfileIsRefused() async {
        let lines = Lines()
        let refusal = await CLIBridge.refusesProCommand(
            profile: "org", operation: "Health audit", onLine: { lines.add($0.text) },
            resolved: resolved(.pro, org: true))
        XCTAssertTrue(refusal?.contains("'org' is an organization-level profile") == true)
        XCTAssertEqual(lines.all.count, 1)
    }

    func testJamfProUnknownAndUnresolvedProfilesAreNotRefusedAndLogNothing() async {
        let lines = Lines()
        for answer: ProfileAuthMethod.Resolved? in [
            .init(authMethod: "oauth2", isTenantLevel: false, product: .pro),
            .init(authMethod: "oauth2", isTenantLevel: false, product: .unknown), nil,
        ] {
            let refusal = await CLIBridge.refusesProCommand(
                profile: "pro-a", operation: "Health audit", onLine: { lines.add($0.text) },
                resolved: { _ in answer })
            XCTAssertNil(refusal)
        }
        XCTAssertTrue(lines.all.isEmpty)
    }
}
