import XCTest
@testable import JamfReports

/// A bare on-prem Jamf host in a shared log is removed once the profile's configured server
/// is seeded (#284). The host is made up.
final class ServerHostRedactionTests: XCTestCase {

    private let line = "[error] request to jss.example.org:8443 failed; retry jss.example.org later"

    func testSeededServerHostIsRedactedWithAndWithoutPort() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["jss.example.org:8443", "jss.example.org"])
        let out = r.redactText(line)
        XCTAssertFalse(out.contains("jss.example.org"), "got: \(out)")
        XCTAssertFalse(out.contains(":8443"), "got: \(out)")
        XCTAssertTrue(out.contains("host-"), "got: \(out)")
    }

    /// A profile named after a label of its own server must not break the host match.
    func testAWorkspaceNameThatIsAHostLabelLeavesNoDomain() {
        let r = DiagnosticRedactor()
        r.seedWorkspaceNames(["jamf"])
        r.seedServerHosts(["jamf.example.org:8443", "jamf.example.org"])
        let out = r.redactText("lookup jamf.example.org: no such host; profile jamf")
        XCTAssertFalse(out.contains("example.org"), "got: \(out)")
        XCTAssertFalse(out.contains("jamf"), "got: \(out)")
    }

    func testAShortWorkspaceNameIsRedactedAsAWholeWord() {
        let r = DiagnosticRedactor()
        r.seedWorkspaceNames(["ABC"])
        let out = r.redactText("collect for abc failed; keychain:jamf-cli/ABC/api-key; ABCD kept")
        XCTAssertFalse(out.contains("abc "), "got: \(out)")
        XCTAssertFalse(out.contains("/ABC/"), "got: \(out)")
        XCTAssertTrue(out.contains("ABCD kept"), "got: \(out)")
    }

    func testUnseededBareHostSurvives() {
        XCTAssertTrue(DiagnosticRedactor().redactText(line).contains("jss.example.org"))
    }

    func testHostMatchesAnyCaseAndIgnoresLookalikes() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["jss.example.org"])
        XCTAssertFalse(r.redactText("JSS.Example.ORG down").contains("Example"))
        XCTAssertTrue(r.redactText("myjss.example.org.test").contains("myjss.example.org.test"))
    }

    func testHostIsLeftAloneWhenHostnameRedactionIsOff() {
        let r = DiagnosticRedactor(redactHostnames: false)
        r.seedServerHosts(["jss.example.org"])
        XCTAssertTrue(r.redactText(line).contains("jss.example.org"))
    }

    func testSharedLogRedactsTheProfilesServer() {
        let shared = LogRedactor.redactedForSharing(
            line, profile: "onprem", scopeIDs: { _ in [] },
            serverHosts: { $0 == "onprem" ? ["jss.example.org:8443", "jss.example.org"] : [] })
        XCTAssertFalse(shared.contains("jss.example.org"), "got: \(shared)")
    }

    func testHostFormsOfAConfiguredURL() {
        let forms = DiagnosticBundleService.hostForms(ofURL:)
        let both = ["jss.example.org:8443", "jss.example.org"]
        XCTAssertEqual(forms("https://jss.example.org:8443/"), both)
        XCTAssertEqual(forms("jss.example.org:8443"), both)
        XCTAssertEqual(forms("https://user:pw@jss.example.org/path?x=1"), ["jss.example.org"])
        XCTAssertEqual(forms(""), [])
    }

    func testServerHostsReadsTheProfileFromJamfCLIConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.yaml")
        try """
        profiles:
            onprem:
                url: https://jss.example.org:8443
                auth-method: oauth2
            other:
                url: https://other.example.net
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(profile: "onprem", configURL: file),
                       ["jss.example.org:8443", "jss.example.org"])
        XCTAssertEqual(
            DiagnosticBundleService.serverHosts(profile: "missing", configURL: file), [])
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem", configURL: dir.appendingPathComponent("absent.yaml")), [])
    }
}
