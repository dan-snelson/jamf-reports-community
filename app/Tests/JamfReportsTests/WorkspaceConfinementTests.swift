import XCTest
@testable import JamfReports

/// A fixed workspace subfolder that is a symlink must never be read, written or pruned: on a
/// shared folder a peer can plant the link. The workspace root itself may be a link.
final class WorkspaceConfinementTests: XCTestCase {

    private let fm = FileManager.default
    private static let label = "com.github.tonyyo11.jamf-reports-community.confined.daily-report"
    private let profile = "confined"
    private var base: URL!
    private var workspace: URL!
    private var elsewhere: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("jrc-confine-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspaces = base.appendingPathComponent("Jamf-Reports", isDirectory: true)
        workspace = workspaces.appendingPathComponent(profile, isDirectory: true)
        elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: base)
    }

    private func link(_ name: String, to target: URL? = nil) throws {
        try fm.createSymbolicLink(
            at: workspace.appendingPathComponent(name), withDestinationURL: target ?? elsewhere)
    }

    private func isEmpty(_ dir: URL) -> Bool {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    // MARK: - The helper

    func testHelperAcceptsARealFolderAndOneThatDoesNotExistYet() throws {
        try fm.createDirectory(
            at: workspace.appendingPathComponent("automation"), withIntermediateDirectories: true)
        XCTAssertNoThrow(
            try WorkspacePaths.confinedFolder(["automation", "logs"], under: workspace))
        XCTAssertNoThrow(try WorkspacePaths.confinedFolder(["backups"], under: workspace))
    }

    func testHelperAcceptsASymlinkedRoot() throws {
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: workspace)
        try fm.createDirectory(
            at: workspace.appendingPathComponent("backups"), withIntermediateDirectories: true)
        let folder = try WorkspacePaths.confinedFolder(["backups"], under: alias)
        XCTAssertEqual(folder.lastPathComponent, "backups")
        XCTAssertEqual(
            folder.deletingLastPathComponent().resolvingSymlinksInPath().path,
            workspace.resolvingSymlinksInPath().path)
    }

    func testHelperRefusesASymlinkAtAnyComponent() throws {
        try link("automation")
        XCTAssertThrowsError(
            try WorkspacePaths.confinedFolder(["automation", "logs"], under: workspace)
        ) {
            guard case WorkspacePaths.PathError.symlinkedSubfolder(let name) = $0 else {
                return XCTFail("expected symlinkedSubfolder, got \($0)")
            }
            XCTAssertEqual(name, "automation")
        }
        try fm.createDirectory(
            at: workspace.appendingPathComponent("state"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: workspace.appendingPathComponent("state/hosts"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(
            try WorkspacePaths.confinedFolder(["state", "hosts"], under: workspace))
    }

    func testRunHistoryAndStateFoldersAreRefusedWhenSymlinked() throws {
        try link("automation")
        let data = workspace.appendingPathComponent("jamf-cli-data")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: data.appendingPathComponent("state"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try WorkspacePaths.runHistoryDir(for: profile))
        XCTAssertThrowsError(try WorkspacePaths.stateDir(for: profile))
    }

    func testDiagnosticsFolderIsPerUserAndPerProfile() throws {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let dir = try WorkspacePaths.diagnosticsDir(for: profile, home: home)
        XCTAssertEqual(
            dir.path, "/Users/someone/Library/Logs/JamfReports/diagnostics/\(profile)")
        XCTAssertFalse(dir.path.hasPrefix(workspace.path))
        XCTAssertThrowsError(try WorkspacePaths.diagnosticsDir(for: "bad\nname", home: home))
    }

    // MARK: - Diagnostic bundle

    func testASymlinkedAutomationFolderYieldsNoLogsAndASkipEntry() throws {
        try "secret-log-line".write(
            to: elsewhere.appendingPathComponent("planted.log"), atomically: true, encoding: .utf8)
        try link("automation")

        var options = DiagnosticBundleOptions()
        options.redact = false
        let sources = try DiagnosticBundleService.makeSources(profile: profile, options: options)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let entries = try DiagnosticBundleService.stageFiles(
            sources: sources, into: staging, redactor: nil, options: options, now: Date())

        XCTAssertFalse(entries.contains { $0.path.hasPrefix("logs/") }, "no log may be staged")
        let skipped = entries.first { $0.path == "automation/logs" }
        XCTAssertEqual(skipped?.skipped, true)
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("logs").path))
        let tree = try String(
            contentsOf: staging.appendingPathComponent("workspace_tree.txt"), encoding: .utf8)
        XCTAssertFalse(tree.contains("planted.log"), "the tree walk must not follow the link")
    }

    // MARK: - Run logs, markers, ledger, claims

    func testTheRecorderWritesNothingThroughASymlinkedAutomationFolder() throws {
        try link("automation")
        let recorder = ScheduledRunRecorder(workspace: workspace, label: Self.label)
        XCTAssertNil(recorder)
        XCTAssertTrue(isEmpty(elsewhere))
    }

    func testTheRecorderStillWorksOnARealFolderBehindASymlinkedRoot() throws {
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: workspace)
        let recorder = try XCTUnwrap(ScheduledRunRecorder(workspace: alias, label: Self.label))
        recorder.finish(exitCode: 0)
        let logs = workspace.appendingPathComponent("automation/logs")
        XCTAssertFalse(isEmpty(logs), "the log lands in the real folder behind the link")
    }

    func testDayMarkerAndLedgerWriteNothingThroughASymlinkedAutomationFolder() throws {
        try link("automation")
        let marker = DayMarker(name: "probe")
        marker.stamp(day: "2026-10-11", in: workspace)
        XCTAssertNil(marker.lastStampedDay(in: workspace))
        let ledger = MetricAlertLedger(workspace: workspace)
        ledger.record(day: "2026-10-11", keys: ["rule"])
        XCTAssertTrue(isEmpty(elsewhere))
    }

    /// A marker that can never be written must not read as unclaimed, or the overdue card and
    /// the hourly re-collect would repeat on every pass; the ledger likewise sends nothing.
    func testARefusedMarkerAndLedgerReadAsAlreadyClaimed() throws {
        let marker = DayMarker(name: "overdue-notify")
        XCTAssertFalse(marker.isStamped("2026-10-11", in: workspace), "a fresh marker is open")
        marker.stamp(day: "2026-10-11", in: workspace)
        XCTAssertTrue(marker.isStamped("2026-10-11", in: workspace))
        XCTAssertFalse(marker.isStamped("2026-10-12", in: workspace))
        XCTAssertEqual(
            MetricAlertLedger(workspace: workspace).pendingKeys(day: "d", keys: ["rule"]), ["rule"])

        try fm.removeItem(at: workspace.appendingPathComponent("automation"))
        try link("automation")
        XCTAssertTrue(marker.isStamped("2026-10-13", in: workspace))
        XCTAssertEqual(
            MetricAlertLedger(workspace: workspace).pendingKeys(day: "d", keys: ["rule"]), [])
    }

    func testHostActivityIsNotRecordedThroughASymlinkedAutomationFolder() throws {
        try link("automation")
        SharedWorkspace.recordActivity(profile: profile)
        XCTAssertTrue(isEmpty(elsewhere))
        XCTAssertTrue(SharedWorkspace.otherHosts(profile: profile).isEmpty)
    }

    // MARK: - Backups

    func testASymlinkedBackupsFolderPrunesNothing() throws {
        for hour in 1...4 {
            let dir = elsewhere.appendingPathComponent("2026082\(hour)T010000", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"label":"scheduled-20260825"}"#.write(
                to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        try link("backups")
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path).count, 4)
    }

    // MARK: - Retention archive

    func testASymlinkedDefaultArchiveFolderArchivesNothing() throws {
        try """
        retention:
          enabled: true
          mode: archive
          snapshot_keep_days: 1
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)
        let kind = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        let old = kind.appendingPathComponent("computers_20200101T000000.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        try link("_archive")

        let acted = SnapshotRetentionService.sweepIfDue(profile: profile)

        XCTAssertEqual(acted, 0)
        XCTAssertTrue(fm.fileExists(atPath: old.path), "the snapshot stays where it is")
        XCTAssertTrue(isEmpty(elsewhere))
    }

    // MARK: - Snapshot kind folders

    func testASymlinkedSnapshotKindFolderTakesNoWrites() throws {
        let data = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: data.appendingPathComponent("computers"), withDestinationURL: elsewhere)
        try fm.createSymbolicLink(
            at: data.appendingPathComponent("patch-release-dates"), withDestinationURL: elsewhere)

        XCTAssertThrowsError(try ReportEngine.saveSnapshot(
            data: Data("[]".utf8), kind: "computers", dataDir: data))
        XCTAssertThrowsError(try ReportEngine.writePatchReleaseDates(
            [["title_id": "1"]], stamp: "20261011T010203", dataDir: data))
        XCTAssertTrue(isEmpty(elsewhere))

        XCTAssertNoThrow(try ReportEngine.saveSnapshot(
            data: Data("[]".utf8), kind: "policies", dataDir: data))
    }

    // MARK: - Retention archive typed elsewhere

    func testATypedArchiveFolderIsNotRefusedBecauseTheDefaultOneIsALink() throws {
        let typed = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("jrc-arch-\(UUID().uuidString.prefix(8))/_archive")
        let typedParent = typed.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: typedParent) }
        try """
        output:
          allow_absolute_paths: true
        retention:
          enabled: true
          mode: archive
          snapshot_keep_days: 1
          archive_dir: "\(typed.path)"
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)
        let kind = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        try "[]".write(to: kind.appendingPathComponent("computers_20200101T000000.json"),
                       atomically: true, encoding: .utf8)
        try link("_archive")

        XCTAssertEqual(SnapshotRetentionService.sweepIfDue(profile: profile), 1)
        XCTAssertTrue(isEmpty(elsewhere))
        XCTAssertTrue(fm.fileExists(atPath: typed.path))
    }
}

// MARK: - Profile name in config.yaml

final class ProfileMismatchDoctorTests: XCTestCase {

    private func config(_ profile: String?) throws -> ReportConfig {
        try ConfigLoader.loadFromString(profile.map { "jamf_cli:\n  profile: \($0)\n" } ?? "")
    }

    func testADifferentProfileIsAFailRowNamingBothAndTheFix() throws {
        let rows = ConfigDoctorService.profileMismatchRows(
            profile: "newname", config: try config("oldname"))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .fail)
        XCTAssertEqual(rows.first?.id, "config.profile_mismatch")
        let text = (rows.first?.detail ?? "") + (rows.first?.hint ?? "")
        XCTAssertTrue(text.contains("oldname") && text.contains("newname"), text)
        XCTAssertTrue(rows.first?.hint?.contains("jamf_cli: profile line") == true)
    }

    func testBlankAndEqualProfilesAreFine() throws {
        XCTAssertEqual(ConfigDoctorService.profileMismatchRows(
            profile: "same", config: try config(nil)), [])
        XCTAssertEqual(ConfigDoctorService.profileMismatchRows(
            profile: "same", config: try config("same")), [])
    }

    func testACaseVariantIsSaidToDifferOnlyInCase() throws {
        let rows = ConfigDoctorService.profileMismatchRows(
            profile: "prod", config: try config("Prod"))
        XCTAssertTrue(rows.first?.detail.contains("differ only in case") == true)
    }

    func testRunIncludesTheRowForAWorkspaceWhoseConfigNamesAnotherProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mismatch-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        let workspace = root.appendingPathComponent("copied", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "jamf_cli:\n  profile: original\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let report = ConfigDoctorService.run(profile: "copied", workspaceRoot: root)

        XCTAssertTrue(report.rows.contains {
            $0.id == "config.profile_mismatch" && $0.severity == .fail
        })
    }
}
