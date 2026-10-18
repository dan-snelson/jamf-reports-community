import Foundation
import XCTest
@testable import JamfReports

/// A failed config write leaves no temporary copy, and a save writes the pinned report
/// folders only where the file sets them or the user chose something other than the default.
final class ConfigSaveSafetyTests: XCTestCase {

    func testAFailedReplaceLeavesNoTemporaryCopy() throws {
        let root = try workspaceRoot()
        let profile = "tmp-clean-\(UUID().uuidString.lowercased())"
        let url = try writeConfig(
            "output:\n  output_dir: Reports\nnotify:\n  url: https://example.invalid/hook\n",
            profile: profile, root: root)
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.outputDir = "Other"
        // An immutable file refuses the swap, which is the step after the temporary file exists.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }
        XCTAssertThrowsError(try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root))

        let folder = url.deletingLastPathComponent().path
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasPrefix(".config.yaml.") && $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testSavingDefaultFoldersWritesNoKeyTheFileNeverSet() throws {
        let root = try workspaceRoot()
        let profile = "no-folders-\(UUID().uuidString.lowercased())"
        let url = try writeConfig("columns:\n  computer_name: Computer Name\n",
                                  profile: profile, root: root)
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        _ = try ConfigService.save(
            profile: profile, state: loaded.state, existingDocument: loaded.document,
            workspaceRoot: root)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("output_dir"), text)
        XCTAssertFalse(text.contains("archive_dir"), text)
    }

    func testSavingKeepsAFolderKeyTheFileSetsAndWritesAChosenOne() throws {
        let root = try workspaceRoot()
        let profile = "folders-\(UUID().uuidString.lowercased())"
        let url = try writeConfig("output:\n  output_dir: Generated Reports\n",
                                  profile: profile, root: root)
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.archiveDir = "Old Runs"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("output_dir: Generated Reports"), text)
        XCTAssertTrue(text.contains("archive_dir: Old Runs"), text)
    }

    private func workspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeConfig(_ text: String, profile: String, root: URL) throws -> URL {
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
