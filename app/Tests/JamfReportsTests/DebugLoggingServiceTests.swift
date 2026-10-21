import XCTest
@testable import JamfReports

final class DebugLoggingServiceTests: XCTestCase {
    // MARK: - Managed logging profile

    private func managedDefaults(
        _ subsystems: [String: Any], forced: Bool = true
    ) throws -> (UserDefaults, String) {
        let suite = "jr-managedlog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            ForcedDefaults(suiteName: suite, forced: forced ? ["Subsystems"] : []))
        defaults.set(subsystems, forKey: "Subsystems")
        return (defaults, suite)
    }

    func test_managed_readsTheBundledProfileShape() throws {
        let (defaults, suite) = try managedDefaults([DebugLoggingService.subsystem: [
            "DEFAULT-OPTIONS": ["Enable-Level": "Debug", "Persist": "Debug"]]])
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DebugLoggingService.managed(defaults: defaults),
                       ManagedDebugLogging(persistVerbose: true, revealPrivate: nil))
    }

    func test_managed_readsTheLevelDictionaryAndPrivateData() throws {
        let (defaults, suite) = try managedDefaults([DebugLoggingService.subsystem: [
            "DEFAULT-OPTIONS": ["Level": ["Enable": "Default", "Persist": "Default"],
                                "Enable-Private-Data": false]]])
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DebugLoggingService.managed(defaults: defaults),
                       ManagedDebugLogging(persistVerbose: false, revealPrivate: false))
    }

    func test_managed_isNilWithoutAProfileForThisSubsystem() throws {
        let options = ["DEFAULT-OPTIONS": ["Persist": "Debug"]]
        let (unforced, suite1) = try managedDefaults(
            [DebugLoggingService.subsystem: options], forced: false)
        defer { unforced.removePersistentDomain(forName: suite1) }
        XCTAssertNil(DebugLoggingService.managed(defaults: unforced))
        let (other, suite2) = try managedDefaults(["com.example.other": options])
        defer { other.removePersistentDomain(forName: suite2) }
        XCTAssertNil(DebugLoggingService.managed(defaults: other))
        XCTAssertNil(DebugLoggingService.managed(defaults: nil))
    }

    func test_managedLoggingText_namesEachSwitchOrNoProfile() {
        XCTAssertTrue(SettingsView.managedLoggingText(
            ManagedDebugLogging(persistVerbose: true, revealPrivate: nil))
            .hasSuffix("verbose logs on, private data not set."))
        XCTAssertEqual(SettingsView.managedLoggingText(nil),
                       "No configuration profile sets logging for Jamf Reports.")
    }

    func test_oneMacCommands() {
        XCTAssertEqual(DebugLoggingService.enableCommand,
            "sudo log config --subsystem com.github.tonyyo11.jamf-reports-community "
            + "--mode \"level:debug,persist:debug\"")
        XCTAssertEqual(DebugLoggingService.resetCommand,
            "sudo log config --subsystem com.github.tonyyo11.jamf-reports-community --reset")
    }
}
