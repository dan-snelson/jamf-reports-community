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

    /// jamf-cli config with three servers, and workspaces `prod` (Pro + Protect) and `edu`
    /// (School + Protect) under a scratch workspaces root.
    private func protectFixture() throws -> (config: URL, root: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("ws", isDirectory: true)
        let school = "school_cli:\n  enabled: true\n  profile: edu\n"
        for (name, product) in [("prod", ""), ("edu", school)] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (product + "protect:\n  enabled: true\n  profile: shield\n")
                .write(to: folder.appendingPathComponent("config.yaml"), atomically: true,
                       encoding: .utf8)
        }
        let config = dir.appendingPathComponent("config.yaml")
        try """
        profiles:
            prod:
                url: https://jss.example.org:8443
            edu:
                url: https://school.example.net
            shield:
                url: https://acme-label.protect.example.com
            elsewhere:
                url: https://other.example.com
        """.write(to: config, atomically: true, encoding: .utf8)
        return (config, root)
    }

    func testServerHostsAddsTheWorkspacesProtectProfile() throws {
        let (config, root) = try protectFixture()
        let prod = DiagnosticBundleService.serverHosts(
            profile: "prod", configURL: config, workspacesRoot: root)
        XCTAssertEqual(prod, ["jss.example.org:8443", "jss.example.org",
                              "acme-label.protect.example.com"])
        let edu = DiagnosticBundleService.serverHosts(
            profile: "edu", configURL: config, workspacesRoot: root)
        XCTAssertEqual(edu, ["school.example.net", "acme-label.protect.example.com"])
        XCTAssertFalse(DiagnosticBundleService.serverHosts(
            profile: "elsewhere", configURL: config, workspacesRoot: root)
            .contains("acme-label.protect.example.com"))
    }

    func testSharedLogRedactsTheProtectHost() throws {
        let (config, root) = try protectFixture()
        let shared = LogRedactor.redactedForSharing(
            "[error] protect alerts failed at acme-label.protect.example.com", profile: "prod",
            scopeIDs: { _ in [] },
            serverHosts: {
                DiagnosticBundleService.serverHosts(
                    profile: $0, configURL: config, workspacesRoot: root)
            })
        XCTAssertFalse(shared.contains("acme-label"), "got: \(shared)")
    }

    func testLoggingExportRedactsEveryProfilesHostAndID() {
        let id = "3f2b8c1e-5d4a-4e7b-9c10-a1b2c3d4e5f6"
        let text = "[collect] a: jss.example.org down\n[collect] b: school.example.net "
            + "Environment '\(id)' not found"
        let shared = LogRedactor.redactedForSharing(
            text, profiles: ["a", "b"],
            scopeIDs: { $0 == "b" ? [id] : [] },
            serverHosts: { $0 == "a" ? ["jss.example.org"] : ["school.example.net"] })
        XCTAssertFalse(shared.contains("jss.example.org"), "got: \(shared)")
        XCTAssertFalse(shared.contains("school.example.net"), "got: \(shared)")
        XCTAssertFalse(shared.contains("3f2b8c1e"), "got: \(shared)")
    }
}
