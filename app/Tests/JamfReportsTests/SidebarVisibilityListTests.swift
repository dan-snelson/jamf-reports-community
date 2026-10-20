import XCTest
@testable import JamfReports

final class SidebarVisibilityListTests: XCTestCase {

    private var listed: [Tab] {
        SettingsView.toggleableGroups(school: false).flatMap(\.tabs)
    }

    /// Every tab the user may hide has a switch, once, and no tab that cannot be hidden does.
    func testEveryHideableTabHasExactlyOneSwitch() {
        let hideable = Tab.allCases.filter { !$0.isCoreTab && $0 != .schoolDevices }
        XCTAssertEqual(Set(listed), Set(hideable))
        XCTAssertEqual(listed.count, hideable.count, "no tab listed twice")
        XCTAssertTrue(listed.allSatisfy { !$0.isCoreTab })
    }

    func testGroupsAndSearchesCanBeHidden() {
        XCTAssertTrue(listed.contains(.groupInventory))
        var visibility = TabVisibility()
        visibility.toggle(.groupInventory)
        XCTAssertFalse(visibility.isVisible(.groupInventory))
        XCTAssertTrue(TabVisibility.parse(visibility.serialize()).isVisible(.protectDashboard))
    }

    func testTheGroupsAreTheSidebarsInTheSidebarsOrder() {
        let sidebar = Tab.navGroups.map(\.label)
        let shown = SettingsView.toggleableGroups(school: false).map(\.label)
        XCTAssertEqual(shown, sidebar.filter { shown.contains($0) })
        let fleet = SettingsView.toggleableGroups(school: false).first { $0.label == "FLEET" }
        XCTAssertEqual(
            fleet?.tabs, [.mobileFleet, .deviceLookup, .protectDashboard, .groupInventory])
        XCTAssertFalse(shown.contains("SYSTEM"), "Settings is core, so its group is empty")
    }

    /// A Jamf School workspace lists only the tabs it has.
    func testSchoolListsOnlyItsOwnTabs() {
        let school = SettingsView.toggleableGroups(school: true).flatMap(\.tabs)
        XCTAssertEqual(Set(school), Tab.schoolTabs.filter { !$0.isCoreTab })
        XCTAssertTrue(school.contains(.schoolDevices))
        XCTAssertFalse(school.contains(.fleet))
        XCTAssertFalse(school.contains(.protectDashboard))
        let withProtect = SettingsView.toggleableGroups(school: true, protectConnected: true)
            .flatMap(\.tabs)
        XCTAssertEqual(Set(withProtect), Set(school).union([.protectDashboard]))
    }
}
