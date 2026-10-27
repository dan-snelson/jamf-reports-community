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

    /// A hand-made Protect login (plain oauth2, no `product:` key, no Protect host) reads as
    /// Jamf Pro only by default, which must not stop Protect from using it.
    func testProtectIsRefusedOnlyForAnExplicitOtherProduct() throws {
        func resolved(_ name: String, auth: String = "oauth2", file: String?)
            throws -> ProfileAuthMethod.Resolved? {
            ProfileAuthMethod.invalidateCache()
            return try ProductGuardSeed.seed(profile: name, authMethod: auth, product: file, in: dir)
        }
        let handMade = try XCTUnwrap(resolved("hand", file: nil))
        XCTAssertEqual(handMade.product, .pro)
        XCTAssertTrue(handMade.productIsDefaulted)
        XCTAssertNil(handMade.protectRefusal(profile: "hand"))
        XCTAssertNotNil(try XCTUnwrap(resolved("keyed", file: "pro")).protectRefusal(profile: "keyed"))
        XCTAssertNotNil(
            try XCTUnwrap(resolved("gw", auth: "platform", file: nil)).protectRefusal(profile: "gw"),
            "the auth method says Jamf Pro")
        XCTAssertNotNil(
            try XCTUnwrap(resolved("sc", auth: "apikey", file: nil)).protectRefusal(profile: "sc"))
        XCTAssertNil(try XCTUnwrap(resolved("pr", file: "protect")).protectRefusal(profile: "pr"))
        XCTAssertNil(handMade.proRefusal(profile: "hand", operation: "x"),
                     "a defaulted Pro login still runs Jamf Pro commands")
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

    // MARK: - config list unreadable

    private func schoolWorkspace(_ name: String) throws {
        let workspaces = dir.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let workspace = workspaces.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "school_cli:\n  enabled: true\n  profile: \"\(name)\"\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    /// With no `config list` answer, an API-key login or a School workspace still has no
    /// bearer token to probe, while an unknown profile is probed as before.
    func testTheProbeIsStillSkippedForSchoolWhenConfigListCannotBeRead() throws {
        let file = dir.appendingPathComponent("jamf-cli-config.yaml")
        try "profiles:\n    campus:\n        auth-method: apikey\n    corp:\n        auth-method: oauth2\n"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(ProfileAuthMethod.skipsProAuthProbe(profile: "campus", configFile: file),
                      "apikey entry in jamf-cli's config file")
        XCTAssertFalse(ProfileAuthMethod.skipsProAuthProbe(profile: "corp", configFile: file))
        XCTAssertFalse(ProfileAuthMethod.skipsProAuthProbe(profile: "absent", configFile: file))

        try schoolWorkspace("school-ws")
        XCTAssertTrue(ProfileAuthMethod.skipsProAuthProbe(profile: "school-ws", configFile: nil),
                      "school_cli in the workspace's config.yaml")
    }

    @MainActor
    func testAuthGuardLetsASchoolWorkspaceThroughWithNoJamfCLI() async throws {
        try schoolWorkspace("school-ws")
        let lines = ProductGuardLines()
        let proceed = await CLIBridge().authGuard(profile: "school-ws", onLine: lines.add)
        XCTAssertTrue(proceed, "no jamf-cli to ask must not read as rejected credentials")
        XCTAssertTrue(lines.all.isEmpty, "\(lines.all)")
    }
}
