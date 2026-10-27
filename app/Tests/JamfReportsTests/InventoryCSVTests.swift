import Foundation
import XCTest
@testable import JamfReports

/// The one-time CSV import reads a file through `InventoryCSV`: it refuses a link unless the
/// person chose the path, refuses a FIFO, and stops at a size cap.
final class InventoryCSVTests: XCTestCase {

    private let fileManager = FileManager.default

    func testReadRefusesALinkAndAnOverCapFileAndReadsANormalOne() throws {
        let root = try makeFolder()
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

    func testAFIFONamedCSVIsRefusedAndNothingBlocks() throws {
        let fifo = try makeFolder().appendingPathComponent("x.csv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try InventoryCSV.read(fifo)) {
            XCTAssertEqual(($0 as? InventoryCSV.ReadError)?.reason, "not a regular file")
        }
    }

    func testBoundedFileFollowsALinkByDefault() throws {
        let root = try makeFolder()
        let real = root.appendingPathComponent("real.csv")
        try writeCSV(to: real)
        let link = root.appendingPathComponent("link.csv")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNoThrow(try BoundedFile.read(link, limit: 1_000))
        XCTAssertThrowsError(try BoundedFile.read(link, limit: 1_000, followSymlinks: false))
    }

    // MARK: - Helpers

    private func writeCSV(to url: URL) throws {
        try "name,serial\nMac,ABC123\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFolder() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
