import Foundation
import XCTest
@testable import JamfReports

/// The folders `ReportEngine.generate` reads and writes belong to the run's profile. The
/// `jamf_cli.profile` in a shared workspace's config.yaml, which a peer can edit, may be blank
/// or equal to it and is otherwise refused.
final class ReportEngineRunProfileTests: XCTestCase {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-run-profile-\(UUID().uuidString)", isDirectory: true)
        for name in ["shared", "victim"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func engine(namedProfile: String?, run: String? = "shared") throws -> ReportEngine {
        var yaml = "charts:\n  enabled: true\n  archive_current_csv: true\n"
            + "  historical_csv_dir: snapshots\n"
        if let namedProfile { yaml += "jamf_cli:\n  profile: \(namedProfile)\n" }
        let config = workspace("shared").appendingPathComponent("config.yaml")
        try yaml.write(to: config, atomically: true, encoding: .utf8)
        return ReportEngine(
            config: try ConfigLoader.load(from: config),
            dataDir: workspace("shared").appendingPathComponent("jamf-cli-data"),
            profile: run)
    }

    private func everything(under folder: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: folder.path)
        return (walker?.allObjects as? [String] ?? []).sorted()
    }

    func testAConfigNamingAnotherProfileIsRefusedWithBothNamesAndWritesNothing() async throws {
        let engine = try engine(namedProfile: "victim")
        let lines = Lines()
        let out = workspace("shared").appendingPathComponent("Generated Reports/r.xlsx")

        do {
            try await engine.generate(outputURL: out, locateJamfCLI: { nil },
                                      onLine: lines.add)
            XCTFail("a mismatched jamf_cli.profile must be refused")
        } catch let error as ReportEngineError {
            guard case .profileMismatch(let named, let run) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(named, "victim")
            XCTAssertEqual(run, "shared")
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("victim") && text.contains("shared"), text)
        }
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[error] ") && $0.contains("victim") },
                      "\(lines.all)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(everything(under: workspace("victim")), [])
    }

    func testABlankOrEqualConfigProfileGeneratesIntoTheRunsOwnFolders() async throws {
        for named in [nil, "shared"] {
            let engine = try engine(namedProfile: named)
            let out = workspace("shared").appendingPathComponent("Generated Reports/r.xlsx")
            try await engine.generate(outputURL: out, locateJamfCLI: { nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "\(named ?? "blank")")
            XCTAssertEqual(everything(under: workspace("victim")), [])
        }
    }

    func testTheRunProfileLeadsWhenTheCallerNamedOne() throws {
        XCTAssertEqual(try engine(namedProfile: nil).runProfile(onLine: nil), "shared")
        XCTAssertEqual(try engine(namedProfile: "shared").runProfile(onLine: nil), "shared")
        XCTAssertThrowsError(try engine(namedProfile: "victim").runProfile(onLine: nil))
    }
}
