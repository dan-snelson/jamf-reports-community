import XCTest
@testable import JamfReports

/// Every read of a workspace's config.yaml stops at `ConfigLoader.maxConfigBytes`: the folder
/// may be shared with Macs and sync tools that can grow the file.
final class ConfigReadCapTests: XCTestCase {

    private let fileManager = FileManager.default
    private var root: URL!
    private var cap: Int { ConfigLoader.maxConfigBytes }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-cap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private func write(_ byteCount: Int, to name: String = "config.yaml", in dir: URL? = nil) throws
        -> URL {
        let url = (dir ?? root).appendingPathComponent(name)
        try Data(repeating: UInt8(ascii: "#"), count: byteCount).write(to: url)
        return url
    }

    func testReadDataThrowsOneByteOverTheCap() throws {
        let url = try write(cap + 1)
        XCTAssertThrowsError(try ConfigLoader.readData(at: url)) { error in
            guard case ConfigLoader.LoadError.fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    func testReadDataAndTextPassAtTheCap() throws {
        let url = try write(cap)
        XCTAssertEqual(try ConfigLoader.readData(at: url).count, cap)
        XCTAssertEqual(try ConfigLoader.readText(at: url).utf8.count, cap)
    }

    func testReadTextRejectsBytesThatAreNotUTF8() throws {
        let url = root.appendingPathComponent("bad.yaml")
        try Data([0xFF, 0xFE, 0xFA]).write(to: url)
        XCTAssertThrowsError(try ConfigLoader.readText(at: url)) { error in
            guard case ConfigLoader.LoadError.encodingError = error else {
                return XCTFail("expected encodingError, got \(error)")
            }
        }
    }

    /// A FIFO planted at the name is refused before any read: opening it must not block, and
    /// the type is checked on the descriptor that is read.
    func testAFifoAtConfigYamlIsRefusedPromptly() throws {
        let fifo = root.appendingPathComponent("config.yaml")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let finished = expectation(description: "the read returns")
        let thrown = ErrorBox()
        DispatchQueue.global().async {
            do { _ = try ConfigLoader.readData(at: fifo) } catch { thrown.set(error) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        guard case ConfigLoader.LoadError.notRegularFile? = thrown.error else {
            return XCTFail("expected notRegularFile, got \(String(describing: thrown.error))")
        }
        XCTAssertThrowsError(try ConfigLoader.load(from: fifo))
    }

    func testADirectoryIsNotAConfigFile() throws {
        XCTAssertThrowsError(try ConfigLoader.readData(at: root))
    }

    func testBoundedFileReadsAtMostTheLimitPlusOne() throws {
        let url = try write(100, to: "x.bin")
        XCTAssertEqual(try BoundedFile.read(url, limit: 100).count, 100)
        XCTAssertThrowsError(try BoundedFile.read(url, limit: 99)) {
            XCTAssertEqual($0 as? BoundedFile.Failure, .tooLarge)
        }
        XCTAssertThrowsError(try BoundedFile.read(root.appendingPathComponent("none"), limit: 9)) {
            XCTAssertEqual($0 as? BoundedFile.Failure, .unreadable(ENOENT))
        }
    }

    func testWorkspacePathsFallsBackToTheDefaultReportsFolderForAnOversizeConfig() throws {
        let workspace = root.appendingPathComponent("capprofile", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        _ = try write(5 * 1_048_576, in: workspace)

        let dir = WorkspacePaths.reportsDir(for: "capprofile", onLine: nil)
        XCTAssertEqual(dir?.lastPathComponent, WorkspacePaths.generatedReportsDirName)
        XCTAssertThrowsError(try WorkspacePaths.outputDir(for: "capprofile")) { error in
            guard case WorkspacePaths.PathError.configReadError = error else {
                return XCTFail("expected configReadError, got \(error)")
            }
        }
    }

    func testThePinReadsNothingFromAnOversizeConfig() throws {
        let workspace = root.appendingPathComponent("pinprofile", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        _ = try write(5 * 1_048_576, in: workspace)
        XCTAssertNil(SharedConfigPin.current(workspace: workspace))
    }
}
