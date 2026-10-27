import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

// MARK: - EngineCorrectnessTests
//
// Covers P10-B findings fixed in Lane H-Eng:
//   P10-B-09  sharedStrings count vs uniqueCount
//   P10-B-10  ECMA-376 §18.3.1 child element order in sheet XML
//   P10-B-11  EMU sizing from PNG pixel dimensions
//   P10-B-18  HtmlReport section map key collision check
//   P10-B-42  XLSXValidator empty sheetData detection
//   P10-B-04  ReportEngine saveSnapshot timestamp format
//   P10-B-06  CSV archival only after successful workbook write
//   P10-B-07  yes/no YAML not coerced to boolean

final class EngineCorrectnessTests: XCTestCase {

    // MARK: - P10-B-09: sharedStrings count vs uniqueCount

    func testSharedStringsCountVsUniqueCount() throws {
        // 5 cell writes, 3 unique strings: "A", "B", "A", "B", "C"
        let wb = Workbook()
        let ws = wb.addSheet("Test")
        ws.write("A", row: 0, col: 0)
        ws.write("B", row: 0, col: 1)
        ws.write("A", row: 1, col: 0)
        ws.write("B", row: 1, col: 1)
        ws.write("C", row: 2, col: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try wb.write(to: url)

        // Extract sharedStrings.xml from the ZIP.
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["xl/sharedStrings.xml"] else {
            XCTFail("sharedStrings.xml not found in XLSX")
            return
        }
        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        let xml = String(data: xmlData, encoding: .utf8) ?? ""

        // count should be 5 (total refs), uniqueCount should be 3.
        XCTAssertTrue(xml.contains("count=\"5\""),
            "count attribute must reflect total cell references (5); got: \(xml.prefix(300))")
        XCTAssertTrue(xml.contains("uniqueCount=\"3\""),
            "uniqueCount must be 3 unique strings; got: \(xml.prefix(300))")
    }

    // MARK: - P10-B-10: ECMA-376 §18.3.1 element order

    func testSheetXMLElementOrderSheetViewsBeforeCols() throws {
        let wb = Workbook()
        let ws = wb.addSheet("Order")
        ws.setColumnWidth(0, 2, 20.0)
        ws.freezePane(row: 1, col: 0)
        ws.write("Value", row: 0, col: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try wb.write(to: url)

        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["xl/worksheets/sheet1.xml"] else {
            XCTFail("sheet1.xml not found"); return
        }
        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        let xml = String(data: xmlData, encoding: .utf8) ?? ""

        let sheetViewsIdx = xml.range(of: "<sheetViews")?.lowerBound
        let colsIdx = xml.range(of: "<cols>")?.lowerBound
        let sheetDataIdx = xml.range(of: "<sheetData>")?.lowerBound

        XCTAssertNotNil(sheetViewsIdx, "<sheetViews> not found")
        XCTAssertNotNil(colsIdx, "<cols> not found")
        XCTAssertNotNil(sheetDataIdx, "<sheetData> not found")

        if let sv = sheetViewsIdx, let cols = colsIdx, let data = sheetDataIdx {
            XCTAssertLessThan(sv, cols,
                "<sheetViews> must appear before <cols> per ECMA-376 §18.3.1")
            XCTAssertLessThan(cols, data,
                "<cols> must appear before <sheetData> per ECMA-376 §18.3.1")
        }
    }

    // MARK: - P10-B-11: EMU sizing from PNG pixel dimensions

    func testEMUSizingFromPNGDimensions() throws {
        // Build a minimal valid 1200×600 PNG (just signature + IHDR + minimal IDAT + IEND).
        let pngData = makePNG(width: 1200, height: 600)

        let wb = Workbook()
        let ws = wb.addSheet("Charts")
        ws.insertImage(row: 0, col: 0, data: pngData, filename: "chart.png")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try wb.write(to: url)

        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["xl/drawings/drawing1.xml"] else {
            XCTFail("drawing1.xml not found"); return
        }
        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        let xml = String(data: xmlData, encoding: .utf8) ?? ""

        // 1200 px / 144 DPI * 914400 EMU/in = 7,620,000
        let expectedCX = 7_620_000
        // 600 px / 144 DPI * 914400 EMU/in = 3,810,000
        let expectedCY = 3_810_000

        XCTAssertTrue(xml.contains("cx=\"\(expectedCX)\""),
            "EMU width should be \(expectedCX); drawing XML: \(xml.prefix(500))")
        XCTAssertTrue(xml.contains("cy=\"\(expectedCY)\""),
            "EMU height should be \(expectedCY); drawing XML: \(xml.prefix(500))")
    }

    // MARK: - Logo anchor

    func testLogoSitsRightOfTheTitleAtItsOwnAspect() throws {
        let wb = Workbook()
        let ws = wb.addSheet("Executive Summary")
        _ = ws.writeSheetHeader(title: "Executive Summary", subtitle: "Fleet KPIs", ncols: 3)
        ws.insertLogo(data: makePNG(width: 400, height: 100), filename: "logo.png")

        // The title is merged over columns 0-2, so the logo starts at column 4, row 0.
        let embed = try XCTUnwrap(ws.imageEmbeds.first)
        XCTAssertEqual(embed.row, 0)
        XCTAssertEqual(embed.col, 4)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try wb.write(to: url)
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["xl/drawings/drawing1.xml"])
        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        let xml = String(data: xmlData, encoding: .utf8) ?? ""

        XCTAssertTrue(xml.contains("<xdr:oneCellAnchor>"), xml)
        XCTAssertFalse(xml.contains("twoCellAnchor"), "a logo must not stretch over cells")
        XCTAssertTrue(xml.contains("<xdr:from><xdr:col>4</xdr:col>"), xml)
        // Half an inch tall; a 4:1 image is two inches wide.
        XCTAssertTrue(xml.contains("<xdr:ext cx=\"1828800\" cy=\"457200\"/>"), xml)
    }

    // MARK: - P10-B-42: XLSXValidator empty sheetData detection

    func testXLSXValidatorDetectsEmptySheetData() throws {
        // Build an XLSX with a sheet that has <sheetData/> (no rows).
        let wb = Workbook()
        _ = wb.addSheet("Empty")
        // Don't write any cells — sheetData will be empty.

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try wb.write(to: url)

        let report = try XLSXValidator().validate(at: url)
        let rowErrors = report.issues.filter { $0.message.contains("no rows") }
        XCTAssertFalse(rowErrors.isEmpty,
            "XLSXValidator must flag a sheet with no row elements")
    }

    // MARK: - P10-B-07: yes/no YAML not coerced to boolean

    func testYAMLYesNoNotCoercedToBoolean() throws {
        // Bare `yes` and `no` must decode as strings under YAML 1.2 semantics.
        // Only `true`/`false` are boolean tokens.
        let yaml = """
        jamf_cli:
          profile: no
        branding:
          org_name: yes
        """
        let config = try ConfigDecoder.loadFromString(yaml)
        XCTAssertEqual(config.jamfCli?.profile, "no",
            "Bare 'no' must remain the string \"no\", not boolean false")
        XCTAssertEqual(config.branding?.orgName, "yes",
            "Bare 'yes' must remain the string \"yes\", not boolean true")
    }

    func testYAMLTrueFalseStillCoercedToBoolean() throws {
        // `true`/`false` must still decode as booleans (YAML 1.2 spec).
        // We verify via a bool-typed field in config: use_cached_data.
        let yaml = """
        jamf_cli:
          use_cached_data: false
        """
        let config = try ConfigDecoder.loadFromString(yaml)
        XCTAssertEqual(config.jamfCli?.useCachedData, false,
            "Bare 'false' must decode as boolean false")
    }

    // MARK: - Sanitized accent color helpers

    func testSanitizedAccentColorAcceptsValidHex() {
        let config = makeBrandingConfig(accentColor: "#2D5EA2")
        XCTAssertEqual(config.sanitizedAccentColor, "#2D5EA2")
    }

    func testSanitizedAccentColorFallsBackOnInvalidInput() {
        for typed in ["not-a-color", "#12345", "#2D5EA2FF", "#GGHHII", "2D5EA2"] {
            let config = makeBrandingConfig(accentColor: typed)
            XCTAssertEqual(config.sanitizedAccentColor, "#2D5EA2", typed)
        }
    }

    func testSanitizedAccentColorAcceptsShortHex() {
        let config = makeBrandingConfig(accentColor: "#ABC")
        XCTAssertEqual(config.sanitizedAccentColor, "#ABC")
    }

    // MARK: - Helpers

    private func makePNG(width: UInt32, height: UInt32) -> Data {
        // Minimal valid PNG: signature + IHDR + minimal IDAT + IEND.
        var data = Data()
        // PNG signature
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR chunk: length=13, type=IHDR, data, CRC (CRC not validated in our tests)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // length = 13
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        func uint32BE(_ v: UInt32) -> [UInt8] {
            [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
             UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        data.append(contentsOf: uint32BE(width))
        data.append(contentsOf: uint32BE(height))
        data.append(contentsOf: [0x08, 0x02, 0x00, 0x00, 0x00]) // 8-bit RGB, no interlace
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC placeholder
        // Minimal IDAT (just a placeholder)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // length = 1
        data.append(contentsOf: [0x49, 0x44, 0x41, 0x54]) // "IDAT"
        data.append(0x00)                                   // data
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC placeholder
        // IEND — full 12-byte chunk with correct CRC
        data.append(contentsOf: [
            0x00, 0x00, 0x00, 0x00,  // length = 0
            0x49, 0x45, 0x4E, 0x44,  // "IEND"
            0xAE, 0x42, 0x60, 0x82,  // correct CRC
        ])
        return data
    }

    private func makeBrandingConfig(accentColor: String?) -> BrandingConfig {
        // Decode from YAML to exercise the real Decodable path.
        var yaml = "branding:\n"
        if let c = accentColor { yaml += "  accent_color: \"\(c)\"\n" }
        let config = try? ConfigDecoder.loadFromString(yaml)
        return config?.branding ?? BrandingConfig()
    }
}
