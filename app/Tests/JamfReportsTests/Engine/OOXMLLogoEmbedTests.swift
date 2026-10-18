import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

/// Tests for the branding.logo_path embed on a workbook's first tab (`ReportEngine.generate`).
///
/// Verifies PNG validation, missing-file handling, and that a valid PNG ends up
/// in `xl/media/image1.png` inside the produced ZIP.
final class OOXMLLogoEmbedTests: XCTestCase {

    // MARK: - Fixtures

    /// Under home: the loader refuses a logo in a system folder, and the temp folder is one.
    private static func logoFolder() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("jrc-logo-\(UUID().uuidString)", isDirectory: true)
    }

    /// Minimal 8-byte valid PNG magic followed by enough bytes to satisfy `Data.prefix`.
    private var validPNGData: Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // Append a minimal IHDR chunk so the file is structurally non-empty.
        bytes += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE]
        return Data(bytes)
    }

    /// JPEG magic bytes — must be rejected by the PNG validator.
    private var nonPNGData: Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    }

    /// Generates a workbook from an empty data folder (the Cover and Compliance Posture tabs
    /// are always written) with `logoPath` as the branding logo, and opens it.
    private func generatedArchive(logoPath: String?, in folder: URL) async throws -> Archive {
        var config = ReportConfig()
        var branding = BrandingConfig()
        branding.logoPath = logoPath
        config.branding = branding
        let engine = ReportEngine(config: config, dataDir: folder.appendingPathComponent("data"))
        let xlsxURL = folder.appendingPathComponent("out.xlsx")
        try await engine.generate(outputURL: xlsxURL, locateJamfCLI: { nil })
        return try XCTUnwrap(Archive(url: xlsxURL, accessMode: .read))
    }

    private func makeFolder() throws -> URL {
        let folder = Self.logoFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Valid PNG embed

    func testValidPNGIsEmbeddedOnTheFirstTabOnly() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logoURL = folder.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        let archive = try await generatedArchive(logoPath: logoURL.path, in: folder)

        XCTAssertNotNil(archive["xl/media/image1.png"],
                        "xl/media/image1.png must be present in the XLSX archive.")
        XCTAssertNotNil(archive["xl/drawings/drawing1.xml"])
        XCTAssertNil(archive["xl/drawings/drawing2.xml"], "the logo goes on one tab, not every tab")
    }

    // MARK: - Missing file

    func testMissingLogoFileProducesWorkbookWithoutImage() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let archive = try await generatedArchive(
            logoPath: folder.appendingPathComponent("nonexistent.png").path, in: folder)

        XCTAssertNil(archive["xl/media/image1.png"],
                     "No image should be embedded when the logo file does not exist.")
    }

    // MARK: - Non-PNG file

    func testNonPNGFileIsRejectedAndProducesNoImage() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fakeLogoURL = folder.appendingPathComponent("logo.png")
        try nonPNGData.write(to: fakeLogoURL)

        let archive = try await generatedArchive(logoPath: fakeLogoURL.path, in: folder)

        XCTAssertNil(archive["xl/media/image1.png"],
                     "Non-PNG file must be rejected; no image should appear in the XLSX archive.")
    }

    // MARK: - No logo configured

    func testNoLogoConfiguredProducesCleanWorkbook() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let archive = try await generatedArchive(logoPath: nil, in: folder)

        XCTAssertNil(archive["xl/media/image1.png"])
        let contentTypes = try entryText(archive, "[Content_Types].xml")
        XCTAssertFalse(contentTypes.contains(#"Extension="png""#),
                       "no images embedded — png Default must not be declared")
    }

    // MARK: - Content type declaration for image parts

    /// Read a ZIP entry's contents as a UTF-8 string.
    private func entryText(_ archive: Archive, _ path: String) throws -> String {
        let entry = try XCTUnwrap(archive[path], "\(path) must exist in the archive")
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// OPC requires every package part to carry a content type. A workbook with
    /// embedded PNGs must declare the png extension Default — without it Excel
    /// reports "We found a problem with some content" and offers to repair the
    /// file (stripping the chart images). Regression test for that exact bug.
    func testImageWorkbookDeclaresPNGContentType() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logoURL = folder.appendingPathComponent("logo.png")
        try validPNGData.write(to: logoURL)

        let archive = try await generatedArchive(logoPath: logoURL.path, in: folder)

        XCTAssertNotNil(archive["xl/media/image1.png"], "precondition: image must be embedded")
        let contentTypes = try entryText(archive, "[Content_Types].xml")
        XCTAssertTrue(
            contentTypes.contains(#"<Default Extension="png" ContentType="image/png"/>"#),
            "image parts require a png content-type Default; got: \(contentTypes)"
        )
    }
}
