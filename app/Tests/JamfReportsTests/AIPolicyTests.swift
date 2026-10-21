import Darwin
import Foundation
import XCTest
@testable import JamfReports

/// `AIPolicy` over a workspace whose config.yaml turns AI and the report summary on.
final class AIPolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()
    private var profile = ""

    override func setUpWithError() throws {
        suiteName = "AIPolicyTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIPolicyTests-\(UUID().uuidString)", isDirectory: true)
        profile = "ai-policy-\(UUID().uuidString.lowercased())"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "ai:\n  enabled: true\n  tier: on_device\n  include_in_reports: true\n"
            .write(to: workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        let suite = suiteName
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    func testAbsentPolicyLeavesTheWorkspaceInCharge() {
        XCTAssertNil(AIPolicy.current(defaults: defaults))
        let config = AIConfigLoader.load(profile: profile, defaults: defaults)
        XCTAssertTrue(config.isUsable)
        XCTAssertTrue(config.writesReportSummary)
        XCTAssertFalse(AIPolicy.locksSettings(defaults: defaults))
        XCTAssertNil(AIPolicy.settingsNote(defaults: defaults))
    }

    func testOffTurnsEverySurfaceOff() {
        defaults.set("off", forKey: AIPolicy.defaultsKey)
        let config = AIConfigLoader.load(profile: profile, defaults: defaults)
        XCTAssertFalse(config.isUsable)
        XCTAssertFalse(config.writesReportSummary)
        XCTAssertTrue(AIPolicy.locksSettings(defaults: defaults))
    }

    func testOnDeviceKeepsTheWorkspaceSettings() {
        defaults.set("onDevice", forKey: AIPolicy.defaultsKey)
        let config = AIConfigLoader.load(profile: profile, defaults: defaults)
        XCTAssertTrue(config.isUsable)
        XCTAssertTrue(config.writesReportSummary)
        XCTAssertFalse(AIPolicy.locksSettings(defaults: defaults))
    }

    func testAnUnknownValueReadsAsOff() {
        for value: Any in ["OnDevice", "any", "", true, 1] {
            defaults.set(value, forKey: AIPolicy.defaultsKey)
            XCTAssertEqual(AIPolicy.current(defaults: defaults), .off, "\(value)")
            XCTAssertFalse(AIConfigLoader.load(profile: profile, defaults: defaults).isUsable)
        }
    }

    func testOnlyTheOnDeviceTierIsAllowed() {
        XCTAssertTrue(AIPolicy.onDevice.allows(.onDevice))
        XCTAssertFalse(AIPolicy.off.allows(.onDevice))
        var config = AIConfig()
        config.enabled = true
        XCTAssertTrue(config.effective(policy: .onDevice).isUsable)
        XCTAssertFalse(config.effective(policy: .off).isUsable)
        XCTAssertTrue(config.effective(policy: nil).isUsable)
    }

    func testWriterRefusesToTurnAIOnWhileOff() throws {
        defaults.set("off", forKey: AIPolicy.defaultsKey)
        var config = AIConfig()
        config.enabled = true
        XCTAssertThrowsError(try AIConfigWriter.save(config, profile: profile, defaults: defaults))
        defaults.removeObject(forKey: AIPolicy.defaultsKey)
        XCTAssertTrue(AIConfigLoader.load(profile: profile, defaults: defaults).isUsable)
    }

    func testSettingsNoteNamesTheProfileWhenForced() throws {
        let forced = try XCTUnwrap(ForcedDefaults(suiteName: suiteName,
                                                  forced: [AIPolicy.defaultsKey]))
        forced.set("off", forKey: AIPolicy.defaultsKey)
        XCTAssertEqual(AIPolicy.settingsNote(defaults: forced), ManagedPreference.note)
        XCTAssertNotEqual(AIPolicy.settingsNote(defaults: defaults), ManagedPreference.note)

        forced.set("onDevice", forKey: AIPolicy.defaultsKey)
        XCTAssertEqual(AIPolicy.settingsNote(defaults: forced),
                       "Your organization limits AI to on-device models.")
        XCTAssertEqual(AIPolicy.settingsNote(defaults: defaults),
                       "The AIPolicy preference on this Mac limits AI to on-device models.")
    }
}
