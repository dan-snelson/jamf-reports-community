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
