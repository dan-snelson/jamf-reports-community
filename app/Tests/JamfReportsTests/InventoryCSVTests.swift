import Foundation
import XCTest
@testable import JamfReports

/// The CSV an onboarding or Devices read takes from `csv-inbox/`, which another Mac can write on a
/// shared workspace: a link, FIFO or directory named `*.csv` is never picked, and a read refuses
/// a link and stops at a size cap.
final class InventoryCSVTests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - Picking

    func testASymlinkNamedCSVIsNotPickedAndIsWarnedAbout() throws {
        let (profile, root) = try makeWorkspace()
        let target = root.appendingPathComponent("secret.txt")
        try "private,data\n1,2\n".write(to: target, atomically: true, encoding: .utf8)
        let link = try inboxURL(root).appendingPathComponent("x.csv")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let warnings = WarningBox()
        let picked = CLIBridge.newestCSV(in: profile, onWarning: warnings.add)

        XCTAssertNil(picked)
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].hasPrefix("[warn]"), warnings.all[0])
        XCTAssertTrue(warnings.all[0].contains("x.csv"), warnings.all[0])
        XCTAssertTrue(warnings.all[0].contains("symbolic link"), warnings.all[0])
    }

    func testARegularCSVIsStillPickedBesideALinkThatIsNewer() throws {
        let (profile, root) = try makeWorkspace()
        let inbox = try inboxURL(root)
        let real = inbox.appendingPathComponent("export.csv")
        try writeCSV(to: real)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: real.path)
        let outside = root.appendingPathComponent("other.csv")
        try writeCSV(to: outside)
        try fileManager.createSymbolicLink(
            at: inbox.appendingPathComponent("newer.csv"), withDestinationURL: outside)

        let warnings = WarningBox()
        let picked = CLIBridge.newestCSV(in: profile, onWarning: warnings.add)

        XCTAssertEqual(picked?.lastPathComponent, "export.csv")
        XCTAssertEqual(warnings.all.count, 1)
    }

    func testAFIFONamedCSVIsNotPickedAndNothingBlocks() throws {
        let (profile, root) = try makeWorkspace()
        let fifo = try inboxURL(root).appendingPathComponent("x.csv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let warnings = WarningBox()
        let picked = CLIBridge.newestCSV(in: profile, onWarning: warnings.add)

        XCTAssertNil(picked)
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertThrowsError(try InventoryCSV.read(fifo)) {
            XCTAssertEqual(
                ($0 as? InventoryCSV.ReadError)?.reason, "not a regular file")
        }
    }

    func testADirectoryNamedCSVIsNotPicked() throws {
        let (profile, root) = try makeWorkspace()
        try fileManager.createDirectory(
            at: try inboxURL(root).appendingPathComponent("x.csv", isDirectory: true),
            withIntermediateDirectories: true)

        let warnings = WarningBox()
        XCTAssertNil(CLIBridge.newestCSV(in: profile, onWarning: warnings.add))
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].contains("directory"), warnings.all[0])
    }

    func testANormalCSVIsPickedWithoutAWarning() throws {
        let (profile, root) = try makeWorkspace()
        let csv = try inboxURL(root).appendingPathComponent("export.csv")
        try writeCSV(to: csv)

        let warnings = WarningBox()
        let picked = CLIBridge.newestCSV(in: profile, onWarning: warnings.add)

        XCTAssertEqual(picked?.lastPathComponent, "export.csv")
        XCTAssertTrue(warnings.all.isEmpty)
    }

    func testDevicesInventoryDoesNotPickALinkToAFileInsideTheWorkspace() throws {
        let (profile, root) = try makeWorkspace()
        let target = root.appendingPathComponent("elsewhere.csv")
        try writeCSV(to: target)
        try fileManager.createSymbolicLink(
            at: try inboxURL(root).appendingPathComponent("link.csv"), withDestinationURL: target)

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)

        XCTAssertTrue(snapshot.devices.isEmpty)
        XCTAssertFalse(snapshot.sourceFiles.contains("link.csv"))
        XCTAssertTrue(
            snapshot.warnings.contains { $0.contains("link.csv") && $0.contains("symbolic link") },
            "\(snapshot.warnings)")
    }

    // MARK: - Reading

    func testReadRefusesALinkAndAnOverCapFileAndReadsANormalOne() throws {
        let (_, root) = try makeWorkspace()
        let real = root.appendingPathComponent("real.csv")
        try writeCSV(to: real)
        let link = root.appendingPathComponent("link.csv")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            try InventoryCSV.read(real), Data("name,serial\nMac,ABC123\n".utf8))
        XCTAssertThrowsError(try InventoryCSV.read(link)) {
            XCTAssertEqual(($0 as? InventoryCSV.ReadError)?.reason, "a symbolic link")
        }
        XCTAssertThrowsError(try InventoryCSV.read(real, limit: 5)) {
            XCTAssertEqual(($0 as? InventoryCSV.ReadError)?.reason, "larger than 0 MB")
        }
        XCTAssertNoThrow(try InventoryCSV.read(link, followLinks: true))
    }

    func testBoundedFileFollowsALinkByDefault() throws {
        let (_, root) = try makeWorkspace()
        let real = root.appendingPathComponent("real.csv")
        try writeCSV(to: real)
        let link = root.appendingPathComponent("link.csv")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNoThrow(try BoundedFile.read(link, limit: 1_000))
        XCTAssertThrowsError(try BoundedFile.read(link, limit: 1_000, followSymlinks: false))
    }

    // MARK: - Helpers

    private final class WarningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func inboxURL(_ root: URL) throws -> URL {
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private func writeCSV(to url: URL) throws {
        try "name,serial\nMac,ABC123\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeWorkspace() throws -> (String, URL) {
        let profile = "invcsv-\(UUID().uuidString.lowercased())"
        let workspaceRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaceRoot.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        let root = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return (profile, root)
    }
}
