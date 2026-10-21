import XCTest
@testable import JamfReports

final class DebugLoggingServiceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-debuglog-\(UUID().uuidString).plist")
    }

    func test_absentFile_readsBothOff() {
        XCTAssertEqual(DebugLoggingService.current(at: tempURL()), .off)
    }

    func test_roundTrip_persistVerboseOnly() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: false), at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url),
                       DebugLoggingState(persistVerbose: true, revealPrivate: false))
    }

    func test_roundTrip_revealPrivate() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: true), at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url),
                       DebugLoggingState(persistVerbose: true, revealPrivate: true))
    }

    func test_revealPrivateDefaultsOff_whenOnlyPersistWritten() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: false), at: url)
        XCTAssertFalse(DebugLoggingService.current(at: url).revealPrivate)
    }

    func test_off_writesEmptyOptions() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(.off, at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url), .off)
    }

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

    func test_managedLoggingText_namesEachSwitch() {
        XCTAssertTrue(SettingsView.managedLoggingText(
            ManagedDebugLogging(persistVerbose: true, revealPrivate: nil))
            .hasSuffix("verbose logs on, private values not set."))
    }
}
