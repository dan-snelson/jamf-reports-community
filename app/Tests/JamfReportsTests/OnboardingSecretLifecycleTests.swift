import XCTest
@testable import JamfReports

/// A secret stays while a field still needs correcting and goes when the binary is refused. The
/// stub is a shell script that must never run in these cases (it counts its calls).
/// The success path (secret cleared before the credential check) is not driven here: it needs
/// the PTY launch gate, which has no test seam.
@MainActor
final class OnboardingSecretLifecycleTests: XCTestCase {
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func stub() throws -> URL {
        let marker = scratch.appendingPathComponent("calls")
        let url = scratch.appendingPathComponent("setup-stub")
        let body = """
            #!/bin/sh
            echo x >> '\(marker.path)'
            """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func calls() -> Int {
        let text = try? String(
            contentsOf: scratch.appendingPathComponent("calls"), encoding: .utf8)
        return text?.split(separator: "\n").count ?? 0
    }

    private func makeFlow(binary: URL?, gatePasses: Bool = true) -> OnboardingFlow {
        OnboardingFlow(
            profileLister: { [] }, binaryLocator: { binary },
            binaryGate: { _ in
                if !gatePasses { throw OnboardingFlow.FlowError.processFailed("untrusted") }
            })
    }

    private func fillProtect(_ flow: OnboardingFlow) {
        flow.protectProfileName = "prot-lifecycle"
        flow.protectURL = "https://acme.protect.jamfcloud.com"
        flow.protectClientID = "client-id"
        flow.protectClientSecret = Data("protect-secret".utf8)
    }

    private func fillSchool(_ flow: OnboardingFlow) {
        flow.schoolProfileName = "school-lifecycle"
        flow.schoolURL = "https://acme.jamfschool.com"
        flow.schoolNetworkID = "4242"
        flow.schoolAPIKey = Data("school-key".utf8)
    }

    func test_aBinaryThatFailsTheSignatureGateIsNotHandedAnySecret() async throws {
        let binary = try stub()
        let protect = makeFlow(binary: binary, gatePasses: false)
        fillProtect(protect)
        await protect.registerProtectProfile()
        XCTAssertNotNil(protect.protectConnectionError)
        XCTAssertTrue(protect.protectClientSecret.isEmpty)

        let school = makeFlow(binary: binary, gatePasses: false)
        fillSchool(school)
        await school.registerSchoolProfile()
        XCTAssertNotNil(school.schoolConnectionError)
        XCTAssertTrue(school.schoolAPIKey.isEmpty)
        XCTAssertEqual(calls(), 0)
    }

    func test_validationFailuresKeepTheTypedSecret() async throws {
        let protect = makeFlow(binary: try stub())
        fillProtect(protect)
        protect.protectURL = "http://acme.protect.jamfcloud.com"
        await protect.registerProtectProfile()
        XCTAssertNotNil(protect.protectConnectionError)
        XCTAssertEqual(protect.protectClientSecret, Data("protect-secret".utf8))

        let school = makeFlow(binary: try stub())
        fillSchool(school)
        school.schoolURL = "http://acme.jamfschool.com"
        await school.registerSchoolProfile()
        XCTAssertNotNil(school.schoolConnectionError)
        XCTAssertEqual(school.schoolAPIKey, Data("school-key".utf8))
        XCTAssertEqual(calls(), 0, "no secret reached a binary")
    }

    func test_aMissingBinaryKeepsTheTypedSecret() async {
        let flow = makeFlow(binary: nil)
        fillProtect(flow)
        await flow.registerProtectProfile()
        XCTAssertEqual(flow.protectClientSecret, Data("protect-secret".utf8))
    }
}
