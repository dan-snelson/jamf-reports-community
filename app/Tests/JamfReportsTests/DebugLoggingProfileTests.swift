import XCTest
@testable import JamfReports

final class DebugLoggingProfileTests: XCTestCase {
    private func profileURL() throws -> URL {
        try XCTUnwrap(DebugLoggingService.bundledProfileURL, "bundled debug-logging .mobileconfig missing")
    }

    func test_profileIsValidPlist_withLoggingPayloadForOurSubsystem() throws {
        let data = try Data(contentsOf: try profileURL())
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(root as? [String: Any])
        let payloads = try XCTUnwrap(dict["PayloadContent"] as? [[String: Any]])
        let logging = try XCTUnwrap(payloads.first {
            ($0["PayloadType"] as? String) == "com.apple.system.logging"
        })
        let subsystems = try XCTUnwrap(logging["Subsystems"] as? [String: Any])
        XCTAssertNotNil(subsystems["com.github.tonyyo11.jamf-reports-community"],
                        "profile must target our OSLog subsystem")
    }

    /// os_log(5): `Enable` and `Persist` sit in a `Level` dictionary under `DEFAULT-OPTIONS`.
    func test_profilePersistsVerbose() throws {
        let data = try Data(contentsOf: try profileURL())
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payload = try XCTUnwrap((root["PayloadContent"] as? [[String: Any]])?.first)
        let options = try XCTUnwrap(((payload["Subsystems"] as? [String: Any])?[
            "com.github.tonyyo11.jamf-reports-community"] as? [String: Any])?["DEFAULT-OPTIONS"]
            as? [String: Any])
        let level = try XCTUnwrap(options["Level"] as? [String: String])
        XCTAssertEqual(level["Enable"], "Debug")
        XCTAssertEqual(level["Persist"], "Debug")
        XCTAssertNil(options["Enable-Level"], "not an os_log key")
    }

    func test_profileDoesNotRevealPrivateData() throws {
        let data = try Data(contentsOf: try profileURL())
        // reveal-private is a local-only, warned opt-in — it must NOT ship in the MDM profile.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Enable-Private-Data"))
    }

    func test_profileScopeIsUser_noEscalation() throws {
        let data = try Data(contentsOf: try profileURL())
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(root as? [String: Any])
        XCTAssertEqual(dict["PayloadScope"] as? String, "User")
    }
}
