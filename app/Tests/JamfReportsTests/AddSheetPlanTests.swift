import XCTest
@testable import JamfReports

final class AddSheetPlanTests: XCTestCase {
    private func profile(
        _ name: String, _ product: JamfCLIProduct = .pro, level: PlatformScopeLevel? = nil
    ) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "https://\(name).example.com", schedules: 0,
                       status: .idle, product: product, platformLevel: level)
    }

    private func unassigned(
        _ profiles: [JamfCLIProfile], workspaces: [String] = [], paired: Set<String> = [],
        unusable: [String: String] = [:]
    ) -> [AddSheetPlan.UnassignedProfile] {
        AddSheetPlan.unassigned(
            profiles: profiles, workspaces: workspaces, paired: paired, unusable: unusable)
    }

    // MARK: - Adoption outcome

    func testAFailedFirstCollectIsReportedNotCalledSetUp() {
        let failed = AddSheetPlan.adoptionOutcome(
            name: "alpha", status: .failed("collect exited 3"))
        XCTAssertNil(failed.message)
        XCTAssertEqual(failed.error, "alpha's workspace was created, but its first collect "
            + "failed (collect exited 3). Fix the cause, then collect from that workspace.")

        let done = AddSheetPlan.adoptionOutcome(name: "alpha", status: .done)
        XCTAssertEqual(done.message, "alpha is set up. Switch to it from the workspace menu.")
        XCTAssertNil(done.error)
    }

    // MARK: - Unassigned profiles

    func testProfilesWithAWorkspaceOrNamedByOneAreLeftOut() {
        let rows = unassigned(
            [profile("prod"), profile("prod-protect", .protect), profile("lab"),
             profile("school", .school), profile("old-school", .school)],
            workspaces: ["prod"], paired: ["prod-protect", "old-school"])
        XCTAssertEqual(rows.map(\.name), ["lab", "school"])
    }

    func testAWorkspaceSpelledInAnotherCaseStillCounts() {
        XCTAssertEqual(unassigned([profile("Prod")], workspaces: ["prod"]), [])
    }

    func testEachProductGetsItsUse() {
        let rows = unassigned([
            profile("pro"), profile("unknown", .unknown), profile("school", .school),
            profile("protect", .protect), profile("cloud", .securityCloud),
        ])
        XCTAssertEqual(rows.map(\.use), [
            .newWorkspace, .newWorkspace, .newWorkspace, .addToCurrent,
            .unavailable(AddSheetPlan.securityCloudReason),
        ])
    }

    func testOrganizationLevelAndUnusableProfilesSayWhy() {
        let rows = unassigned(
            [profile("org", level: .organization), profile("env", level: .environment),
             profile("bad name")],
            unusable: ["bad name": "Rename it."])
        XCTAssertEqual(rows.map(\.use), [
            .unavailable(PlatformScopeLevel.organizationLevelReason), .newWorkspace,
            .unavailable("Rename it."),
        ])
    }

    func testRowsKeepJamfCLIsOrderAndFacts() {
        let rows = unassigned([profile("b", .school), profile("a")])
        XCTAssertEqual(rows.map(\.name), ["b", "a"])
        XCTAssertEqual(rows.first?.product, .school)
        XCTAssertEqual(rows.first?.url, "https://b.example.com")
    }

    // MARK: - Preselection

    private func preselection(
        _ profiles: [JamfCLIProfile], acceptsProtect: Bool = true,
        requested: AddSheetPlan.NewProduct? = nil
    ) -> AddSheetPlan.Choice {
        AddSheetPlan.preselection(
            unassigned: unassigned(profiles), currentAcceptsProtect: acceptsProtect,
            requested: requested)
    }

    func testAnMDMProfileOpensNewWorkspace() {
        XCTAssertEqual(preselection([profile("lab")]), .newWorkspace)
        XCTAssertEqual(preselection([profile("school", .school)]), .newWorkspace)
    }

    func testAProtectProfileOpensAddToCurrent() {
        XCTAssertEqual(preselection([profile("p", .protect)]), .addToCurrent)
    }

    func testAnMDMProfileWinsOverAProtectProfile() {
        XCTAssertEqual(preselection([profile("p", .protect), profile("lab")]), .newWorkspace)
    }

    func testProtectDoesNotOpenAddToCurrentWhenTheWorkspaceCannotTakeIt() {
        XCTAssertEqual(preselection([profile("p", .protect)], acceptsProtect: false),
                       .newWorkspace)
    }

    func testARequestedProductOpensNewWorkspace() {
        XCTAssertEqual(preselection([profile("p", .protect)], requested: .jamfSchool),
                       .newWorkspace)
    }

    func testNothingUnassignedOrOnlyUnavailableOpensNewWorkspace() {
        XCTAssertEqual(preselection([]), .newWorkspace)
        XCTAssertEqual(preselection([profile("cloud", .securityCloud)]), .newWorkspace)
    }
}
