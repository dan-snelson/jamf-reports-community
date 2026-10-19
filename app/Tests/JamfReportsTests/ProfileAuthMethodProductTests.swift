import Foundation
import XCTest
@testable import JamfReports

/// `ProfileAuthMethod.Resolved.product`: filled from jamf-cli's config file, through
/// `ProfileService.derivedProduct`, and the refusal that follows from it.
final class ProfileAuthMethodProductTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("product-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        try? FileManager.default.removeItem(at: dir)
    }

    private func product(_ name: String, auth: String = "oauth2", file: String?) throws
        -> JamfCLIProduct? {
        ProfileAuthMethod.invalidateCache()
        return try ProductGuardSeed.seed(profile: name, authMethod: auth, product: file, in: dir)?
            .product
    }

    func testProtectComesFromTheConfigFileSinceConfigListShowsOAuth2() throws {
        XCTAssertEqual(try product("p", file: "protect"), .protect)
    }

    func testTheOtherProductsAndPlainProfiles() throws {
        XCTAssertEqual(try product("s", file: "security"), .securityCloud)
        XCTAssertEqual(try product("s", auth: "apikey", file: nil), .school)
        XCTAssertEqual(try product("s", file: "school"), .school)
        XCTAssertEqual(try product("s", file: "pro"), .pro)
        XCTAssertEqual(try product("s", file: nil), .pro, "an absent product: key is Jamf Pro")
        XCTAssertEqual(try product("s", file: "future-product"), .unknown)
    }

    func testAProfileTheFileDoesNotHoldIsUnknownNotPro() throws {
        let stub = dir.appendingPathComponent("stub")
        try "#!/bin/sh\nprintf '%s' '[{\"name\":\"x\",\"auth-method\":\"oauth2\"}]'\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let resolved = ProfileAuthMethod.resolve(profile: "x", binary: stub, configFile: nil)
        XCTAssertEqual(resolved?.product, .unknown)
        XCTAssertNil(resolved?.proRefusal(profile: "x", operation: "Backup"))
    }

    func testRefusalWordingAndWhatRuns() {
        func refusal(_ product: JamfCLIProduct, org: Bool = false) -> String? {
            ProfileAuthMethod.Resolved(
                authMethod: "oauth2", isTenantLevel: false, isOrganizationLevel: org,
                product: product).proRefusal(profile: "p", operation: "Backup")
        }
        XCTAssertEqual(refusal(.protect), "Backup is a Jamf Pro command; 'p' is a Jamf Protect profile")
        XCTAssertEqual(refusal(.school), "Backup is a Jamf Pro command; 'p' is a Jamf School profile")
        XCTAssertEqual(refusal(.securityCloud),
                       "Backup is a Jamf Pro command; 'p' is a Jamf Security Cloud profile")
        XCTAssertTrue(refusal(.pro, org: true)?.contains("organization-level") == true)
        XCTAssertNil(refusal(.pro))
        XCTAssertNil(refusal(.unknown))
    }

    func testProtectRefusalNamesAKnownOtherProductOnly() {
        func refusal(_ product: JamfCLIProduct) -> String? {
            ProfileAuthMethod.Resolved(
                authMethod: "oauth2", isTenantLevel: false, isOrganizationLevel: false,
                product: product).protectRefusal(profile: "p")
        }
        XCTAssertEqual(refusal(.pro), "'p' is a Jamf Pro profile, not a Jamf Protect profile")
        XCTAssertEqual(refusal(.school), "'p' is a Jamf School profile, not a Jamf Protect profile")
        XCTAssertNil(refusal(.protect))
        XCTAssertNil(refusal(.unknown))
    }

    func testOrganizationLevelPlatformProfileIsRefused() throws {
        ProfileAuthMethod.invalidateCache()
        let resolved = try ProductGuardSeed.seed(
            profile: "org", authMethod: "platform", in: dir)
        XCTAssertEqual(resolved?.isOrganizationLevel, true)
        XCTAssertEqual(resolved?.product, .pro)
        XCTAssertNotNil(ProfileAuthMethod.refusal(profile: "org", operation: "Collect"))
    }

    func testAnUnresolvedProfileRuns() {
        XCTAssertNil(ProfileAuthMethod.refusal(profile: "never-seeded", operation: "Collect"),
                     "no jamf-cli to ask: could not ask is not a refusal")
        XCTAssertFalse(ProfileAuthMethod.skipsProAuthProbe(profile: "never-seeded"))
    }

    func testAuthProbeIsSkippedForAnotherProductOnly() throws {
        _ = try product("pr", file: "protect")
        XCTAssertTrue(ProfileAuthMethod.skipsProAuthProbe(profile: "pr"))
        _ = try product("jp", file: "pro")
        XCTAssertFalse(ProfileAuthMethod.skipsProAuthProbe(profile: "jp"))
        _ = try product("sc", auth: "apikey", file: nil)
        XCTAssertTrue(ProfileAuthMethod.skipsProAuthProbe(profile: "sc"))
    }
}
