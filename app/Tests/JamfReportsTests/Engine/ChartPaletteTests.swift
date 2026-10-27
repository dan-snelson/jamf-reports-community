import CoreGraphics
import XCTest
@testable import JamfReports

final class ChartPaletteTests: XCTestCase {
    /// hashValue is seeded per process, so equality inside one run cannot prove stability;
    /// pinning the unmapped color to the version number does.
    func testUnmappedMajorVersionColorIsAFunctionOfTheNumber() {
        XCTAssertEqual(ChartPalette.colorForMajorVersion("27"), ChartPalette.color(for: 27))
        XCTAssertEqual(ChartPalette.colorForMajorVersion("27"), ChartPalette.colorForMajorVersion("27"))
        XCTAssertNotEqual(ChartPalette.colorForMajorVersion("27"), ChartPalette.colorForMajorVersion("28"))
    }

    func testMappedMajorVersionKeepsItsColor() {
        XCTAssertEqual(ChartPalette.colorForMajorVersion("15"), ChartPalette.majorVersionColors["15"])
    }

    func testNonNumericVersionFallbackIsStable() {
        let sum = "beta".utf8.reduce(0) { $0 &+ Int($1) }
        XCTAssertEqual(ChartPalette.colorForMajorVersion("beta"), ChartPalette.color(for: sum))
    }
}

final class ComplianceBandColorTests: XCTestCase {
    private typealias Band = ComplianceBandingService.Band

    func testWorkbookBandColorsMatchTheAppBandColors() {
        let bands: [Band] = [.pass, .low, .medLow, .medium, .high, .noData]
        let workbook = ChartPalette.complianceBandColorsWithNoData
        XCTAssertEqual(workbook.count, bands.count)
        for (band, color) in zip(bands, workbook) {
            XCTAssertEqual(color, ChartPalette.cgColor(hex: band.colorHex), band.label)
        }
        XCTAssertEqual(ChartPalette.cgColor(hex: 0x30D158).components?.first ?? 0, 0x30 / 255.0,
                       accuracy: 0.001)
    }

    func testDemoBandsUseTheAppBandColors() {
        let expected = [Band.pass, .low, .medLow, .medium, .high].map(\.colorHex)
        XCTAssertEqual(DemoData.complianceBands.map(\.colorHex), expected)
    }

    func testLegendTextWidthGrowsWithTheLabel() {
        XCTAssertGreaterThan(ChartRenderer.textWidth("Med-Low (11–30)", fontSize: 9),
                             ChartRenderer.textWidth("Pass", fontSize: 9))
    }
}
