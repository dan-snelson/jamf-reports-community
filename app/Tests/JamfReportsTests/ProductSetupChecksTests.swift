import XCTest
@testable import JamfReports

final class ProductSetupChecksTests: XCTestCase {

    private func failure(_ exit: Int32, _ message: String) -> ConnectionCheck.Attempt {
        let object: [String: Any] = ["error": "request failed", "message": message]
        return (exitCode: exit, stdout: (try? JSONSerialization.data(withJSONObject: object))
            ?? Data())
    }

    func testTheCheckIsOneReadTheCollectAlsoMakesOnTheSavedProfile() {
        XCTAssertEqual(ProductSetupChecks.credentialArguments(.protect, profile: "-p2"),
                       ["-p", "-p2", "--no-input", "protect", "plans", "list", "--output", "json"])
        XCTAssertEqual(ProductSetupChecks.credentialArguments(.school, profile: "Albion"),
                       ["-p", "Albion", "--no-input", "school", "locations", "list",
                        "--output", "json"])
    }

    func testOnlyAFailedReadStopsTheConnection() {
        XCTAssertEqual(ProductSetupChecks.verdict((0, Data("[]".utf8)), product: .school),
                       .accepted)
        guard case .failed(let text) = ProductSetupChecks.verdict(
            failure(1, "401 Unauthorized"), product: .school) else {
            return XCTFail("a failed read is not recorded")
        }
        XCTAssertTrue(text.contains("exit 1: 401 Unauthorized"), text)
        XCTAssertTrue(text.contains("network ID and API key"), text)
        guard case .failed(let protect) = ProductSetupChecks.verdict(
            (3, Data()), product: .protect) else { return XCTFail("exit 3 is a failure") }
        XCTAssertTrue(protect.contains("client ID and secret"), protect)
    }

    func testATimeoutNoLaunchOrMissingPermissionStillConnectsWithANote() {
        for attempt: ConnectionCheck.Attempt? in [
            (CLIBridge.exitCodeTimedOut, Data()), nil,
            failure(CLIBridge.exitCodePermissionDenied, "permission denied (HTTP 403)"),
        ] {
            guard case .note = ProductSetupChecks.verdict(attempt, product: .protect) else {
                return XCTFail("\(String(describing: attempt)) blocks the connection")
            }
        }
    }

    func testTheDefaultIsPutBackOnlyWhenSetupReplacedAnother() {
        XCTAssertEqual(ProductSetupChecks.setDefaultArguments(previous: "-prod", setUp: "prot"),
                       ["config", "set-default", "--", "-prod"])
        XCTAssertNil(ProductSetupChecks.setDefaultArguments(previous: "prot", setUp: "prot"))
        XCTAssertNil(ProductSetupChecks.setDefaultArguments(previous: nil, setUp: "prot"))
    }

    func testNotesJoinInOrderAndNoneIsNil() {
        XCTAssertEqual(ProductSetupChecks.joined("a", nil, "", "b"), "a b")
        XCTAssertNil(ProductSetupChecks.joined(nil, ""))
    }
}
