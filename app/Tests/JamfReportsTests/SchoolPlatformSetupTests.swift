import XCTest
@testable import JamfReports

/// Jamf School's Platform API fields: the `school setup` stdin, redaction and clearing, the
/// blueprints check, the Data Sources row and the re-authentication prefill. No jamf-cli runs.
@MainActor
final class SchoolPlatformSetupTests: XCTestCase {

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func failure(_ exit: Int32, _ message: String) -> ConnectionCheck.Attempt {
        let object: [String: Any] = ["error": "request failed", "message": message]
        return (exitCode: exit, stdout: (try? JSONSerialization.data(withJSONObject: object))
            ?? Data())
    }

    private func resolved(tenant: Bool) -> ProfileAuthMethod.Resolved {
        ProfileAuthMethod.Resolved(authMethod: "apikey", isTenantLevel: tenant, product: .school)
    }

    // MARK: - stdin

    func testSchoolStdinWithoutPlatformAnswersNo() {
        XCTAssertEqual(
            text(OnboardingFlow.schoolStdin(networkID: "net", apiKey: Data("key".utf8))),
            "net\nkey\nn\n")
    }

    func testSchoolStdinWithPlatformAnswersEveryPromptInOrder() {
        let expected: [GatewayRegion: String] = [.us: "1", .eu: "2", .apac: "3"]
        for region in GatewayRegion.allCases {
            let data = OnboardingFlow.schoolStdin(
                networkID: "net", apiKey: Data("key".utf8),
                platform: (region, "tenant-1", "client-1", Data("s3cr3t".utf8)))
            XCTAssertEqual(text(data),
                           "net\nkey\ny\n\(expected[region] ?? "?")\ntenant-1\nclient-1\ns3cr3t\n")
        }
    }

    func testFlowStdinFollowsTheSwitch() {
        let flow = OnboardingFlow()
        flow.schoolNetworkID = " net "
        flow.schoolAPIKey = Data("key".utf8)
        flow.schoolPlatformRegion = .eu
        flow.schoolPlatformTenantID = " tenant-1 "
        flow.schoolPlatformClientID = "client-1"
        flow.schoolPlatformClientSecret = Data("s3cr3t".utf8)
        XCTAssertEqual(text(flow.schoolSetupStdin()), "net\nkey\nn\n")
        flow.schoolPlatformEnabled = true
        XCTAssertEqual(text(flow.schoolSetupStdin()),
                       "net\nkey\ny\n2\ntenant-1\nclient-1\ns3cr3t\n")
    }

    // MARK: - Redaction and clearing

    func testRedactionRemovesEveryCredential() {
        let flow = OnboardingFlow()
        flow.schoolNetworkID = "network-4242"
        flow.schoolAPIKey = Data("api-key-value".utf8)
        flow.schoolPlatformTenantID = "tenant-abcdef"
        flow.schoolPlatformClientID = "client-id-12345"
        flow.schoolPlatformClientSecret = Data("client-secret-xyz".utf8)
        let output = flow.schoolRedactedOutput(
            "network-4242 api-key-value tenant-abcdef client-id-12345 client-secret-xyz")
        for value in ["network-4242", "api-key-value", "tenant-abcdef", "client-id-12345",
                      "client-secret-xyz"] {
            XCTAssertFalse(output.contains(value), value)
        }
    }

    func testClearingWipesBothSchoolSecrets() {
        let flow = OnboardingFlow()
        flow.schoolAPIKey = Data("api-key-value".utf8)
        flow.schoolAPIKeyFieldHasText = true
        flow.schoolPlatformClientSecret = Data("client-secret-xyz".utf8)
        flow.schoolPlatformSecretFieldHasText = true
        flow.clearSchoolSecrets()
        XCTAssertTrue(flow.schoolAPIKey.isEmpty)
        XCTAssertTrue(flow.schoolPlatformClientSecret.isEmpty)
        XCTAssertFalse(flow.schoolAPIKeyFieldHasText)
        XCTAssertFalse(flow.schoolPlatformSecretFieldHasText)
    }

    func testPreviousStepFromSchoolConnectClearsThePlatformSecret() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .schoolConnect
        flow.schoolPlatformClientSecret = Data("client-secret-xyz".utf8)
        flow.previousStep()
        XCTAssertTrue(flow.schoolPlatformClientSecret.isEmpty)
    }

    func testConnectNeedsThePlatformFieldsOnlyWithTheSwitchOn() {
        let flow = OnboardingFlow()
        flow.schoolURL = "https://school.jamfcloud.com"
        flow.schoolNetworkID = "net"
        flow.schoolAPIKey = Data("key".utf8)
        XCTAssertTrue(flow.canAttemptSchoolConnect)
        flow.schoolPlatformEnabled = true
        XCTAssertFalse(flow.canAttemptSchoolConnect)
        flow.schoolPlatformTenantID = "-bad"
        flow.schoolPlatformClientID = "client"
        flow.schoolPlatformClientSecret = Data("secret".utf8)
        XCTAssertFalse(flow.canAttemptSchoolConnect, "a tenant ID read as a flag")
        flow.schoolPlatformTenantID = "tenant-1"
        XCTAssertTrue(flow.canAttemptSchoolConnect)
    }

    // MARK: - After the fact: Update credentials

    func testUpdateRerunsSchoolSetupForTheSameProfileAndStoredURL() {
        let flow = OnboardingFlow()
        ReauthenticateSheet.prefillSchool(
            flow, profile: "Albion", url: "https://albion.jamfcloud.com",
            platform: .notConfigured, opensPlatform: true)
        XCTAssertTrue(flow.schoolPlatformEnabled)
        XCTAssertEqual(
            OnboardingFlow.schoolArguments(profile: flow.schoolProfileName, url: flow.schoolURL),
            ["school", "setup", "--profile-name", "Albion",
             "--url", "https://albion.jamfcloud.com", "--no-color"])
    }

    func testReauthOfAProfileWithPlatformFieldsNeverAnswersNo() {
        let row = SchoolPlatformRow.state(resolved: resolved(tenant: true), lastCheck: nil)
        let flow = OnboardingFlow()
        ReauthenticateSheet.prefillSchool(
            flow, profile: "Albion", url: "https://albion.jamfcloud.com",
            platform: row, opensPlatform: false)
        flow.schoolNetworkID = "net"
        flow.schoolAPIKey = Data("key".utf8)
        XCTAssertTrue(text(flow.schoolSetupStdin()).hasPrefix("net\nkey\ny\n"))
        XCTAssertFalse(ReauthenticateSheet.canVerifySchool(
            isBusy: false, urlValid: true, networkID: "net", hasKey: true,
            platformComplete: !flow.schoolPlatformEnabled || flow.isSchoolPlatformComplete),
            "saving waits for the Platform API fields")
    }

    func testTurningThePlatformSwitchOffWarnsWhenItWouldRemoveAccess() {
        XCTAssertNotNil(ReauthenticateSheet.platformRemovalWarning(
            platform: .configured, enabled: false))
        XCTAssertNotNil(ReauthenticateSheet.platformRemovalWarning(
            platform: .rejected, enabled: false))
        XCTAssertNotNil(ReauthenticateSheet.platformRemovalWarning(
            platform: .unknown, enabled: false))
        XCTAssertNil(ReauthenticateSheet.platformRemovalWarning(
            platform: .notConfigured, enabled: false))
        XCTAssertNil(ReauthenticateSheet.platformRemovalWarning(
            platform: .configured, enabled: true))
        XCTAssertNil(ReauthenticateSheet.platformRemovalWarning(platform: nil, enabled: false))
    }

    // MARK: - Data Sources row

    func testRowStateComesFromTheTenantID() {
        XCTAssertEqual(SchoolPlatformRow.state(resolved: nil, lastCheck: nil), .unknown)
        XCTAssertEqual(SchoolPlatformRow.state(resolved: resolved(tenant: false), lastCheck: nil),
                       .notConfigured)
        XCTAssertEqual(SchoolPlatformRow.state(resolved: resolved(tenant: true), lastCheck: nil),
                       .configured)
        XCTAssertEqual(SchoolPlatformRow.state(
            resolved: resolved(tenant: true), lastCheck: .rejectedTenant), .rejected)
        XCTAssertEqual(SchoolPlatformRow.state(
            resolved: resolved(tenant: true), lastCheck: .accepted(blueprints: 2)), .configured)
        XCTAssertEqual(SchoolPlatformRow.notConfigured.actionTitle, "Add\u{2026}")
        XCTAssertEqual(SchoolPlatformRow.rejected.actionTitle, "Update\u{2026}")
    }

    // MARK: - SchoolPlatformCheck

    func testCheckArguments() {
        XCTAssertEqual(SchoolPlatformCheck.arguments(profile: "Albion"),
                       ["-p", "Albion", "--no-input", "school", "blueprints", "list",
                        "--output", "json"])
    }

    func testAcceptedCountsBlueprints() {
        XCTAssertEqual(SchoolPlatformCheck.verdict((0, Data(#"[{"id":"a"},{"id":"b"}]"#.utf8))),
                       .accepted(blueprints: 2))
        XCTAssertEqual(SchoolPlatformCheck.verdict((0, Data("[]".utf8))),
                       .accepted(blueprints: 0))
        XCTAssertEqual(SchoolPlatformCheck.verdict((0, Data("not json".utf8))),
                       .accepted(blueprints: nil))
    }

    func testExitFiveIsAMissingPermission() {
        let verdict = SchoolPlatformCheck.verdict(failure(5, "permission denied (HTTP 403)"))
        XCTAssertEqual(verdict, .missingPermission)
        XCTAssertTrue(verdict.message.contains("blueprints:read"))
    }

    func testARejectedScopeIsARejectedTenant() {
        let owned = failure(5, #"permission denied (HTTP 403): {"code":"OWNERSHIP_FORBIDDEN"}"#)
        XCTAssertEqual(SchoolPlatformCheck.verdict(owned), .rejectedTenant)
        let unknown = failure(4, "[ENVIRONMENT_NOT_FOUND] Environment 'x' not found.")
        XCTAssertEqual(SchoolPlatformCheck.verdict(unknown), .rejectedTenant)
        XCTAssertTrue(SchoolPlatformCheck.Verdict.rejectedTenant.message
            .contains("The Jamf Account gateway does not accept this tenant ID"))
    }

    func testOtherOutcomesAreUndecidedWithTheReason() {
        XCTAssertEqual(SchoolPlatformCheck.verdict(failure(1, "dial tcp: timeout")),
                       .undecided(reason: "exit 1: dial tcp: timeout"))
        XCTAssertEqual(SchoolPlatformCheck.verdict((CLIBridge.exitCodeTimedOut, Data())),
                       .undecided(reason: "no answer within 60 seconds"))
        XCTAssertEqual(SchoolPlatformCheck.verdict(nil),
                       .undecided(reason: "jamf-cli did not start"))
    }

    func testUndecidedReasonIsRedactedAndCapped() {
        let noisy = "dial tcp 10.20.30.40:443 to acme.api.jamfcloud.com for admin@example.org "
            + String(repeating: "x", count: 300)
        guard case .undecided(let reason) = SchoolPlatformCheck.verdict(
            failure(1, noisy), profile: "Albion") else { return XCTFail("not undecided") }
        for leak in ["10.20.30.40", "jamfcloud", "acme", "admin@example.org"] {
            XCTAssertFalse(reason.contains(leak), "\(leak) in: \(reason)")
        }
        XCTAssertTrue(reason.hasPrefix("exit 1: dial tcp"), reason)
        XCTAssertLessThanOrEqual(reason.count, "exit 1: ".count + 200)
    }

    func testRunPassesTheArgumentsToTheRunner() async {
        let seen = SeenArguments()
        let verdict = await SchoolPlatformCheck.run(profile: "Albion") { arguments in
            await seen.record(arguments)
            return (exitCode: 0, stdout: Data("[{}]".utf8))
        }
        XCTAssertEqual(verdict, .accepted(blueprints: 1))
        let recorded = await seen.arguments
        XCTAssertEqual(recorded, [SchoolPlatformCheck.arguments(profile: "Albion")])
    }
}

private actor SeenArguments {
    var arguments: [[String]] = []
    func record(_ value: [String]) { arguments.append(value) }
}
