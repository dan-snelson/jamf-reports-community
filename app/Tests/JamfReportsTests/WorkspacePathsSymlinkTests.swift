import XCTest
@testable import JamfReports

/// A link planted at `Generated Reports` or the default `archive` folder must not send report
/// writes elsewhere (#284).
final class WorkspacePathsSymlinkTests: XCTestCase {

    private let fileManager = FileManager.default
    private let profile = "symlinkpaths"

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// A workspace with an empty config.yaml and a separate folder a link can point at.
    private func makeWorkspace() throws -> (workspace: URL, elsewhere: URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try "output: {}\n".write(to: workspace.appendingPathComponent("config.yaml"),
                                 atomically: true, encoding: .utf8)
        return (workspace, elsewhere)
    }

    func testSymlinkedGeneratedReportsIsNotUsedAsTheFallback() throws {
        let (workspace, elsewhere) = try makeWorkspace()
        try fileManager.createSymbolicLink(
            at: workspace.appendingPathComponent("Generated Reports"),
            withDestinationURL: elsewhere)
        let lines = LineBox()
        let dir = WorkspacePaths.reportsDir(for: profile) { lines.add($0.text) }
        XCTAssertNil(dir)
        let warns = lines.all.filter { $0.hasPrefix("[warn]") }
        XCTAssertEqual(warns.count, 1)
        XCTAssertTrue(warns.first?.contains("symbolic link") == true)
        XCTAssertNil(WorkspacePaths.readableReportsDir(for: profile))
    }

    func testPlainGeneratedReportsFallbackStillWorks() throws {
        let (workspace, _) = try makeWorkspace()
        let dir = WorkspacePaths.reportsDir(for: profile, onLine: nil)
        XCTAssertEqual(dir?.path, workspace.appendingPathComponent("Generated Reports").path)
    }

    func testSymlinkedDefaultArchiveFolderIsRefused() throws {
        let (workspace, elsewhere) = try makeWorkspace()
        let output = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: output.appendingPathComponent("archive"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try WorkspacePaths.archiveDir(for: profile)) { error in
            guard case WorkspacePaths.PathError.symlinkedSubfolder = error else {
                return XCTFail("expected symlinkedSubfolder, got \(error)")
            }
        }
    }

    func testDefaultArchiveFolderWithoutALinkIsUnderTheOutputFolder() throws {
        let (workspace, _) = try makeWorkspace()
        let archive = try WorkspacePaths.archiveDir(for: profile)
        XCTAssertEqual(
            archive.path,
            workspace.appendingPathComponent("Generated Reports/archive").path)
    }
}
