import XCTest
@testable import JamfReports

/// `DateParser` is the one date reader for the report engine: the device reader's forms first,
/// then the zone-less and slash forms. A string nothing reads is nil, never a number.
final class DateParserTests: XCTestCase {

    private func local(_ format: String, _ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.date(from: text)
    }

    func testReadsEveryFormatTheReportsMeet() throws {
        let parser = DateParser()
        let expected = try XCTUnwrap(local("yyyy-MM-dd HH:mm:ss", "2026-03-04 05:06:07"))
        XCTAssertEqual(parser.parse("2026-03-04 05:06:07"), expected)
        XCTAssertEqual(parser.parse("2026-03-04T05:06:07"), expected, "zone-less T form")
        XCTAssertEqual(parser.parse("03/04/2026 05:06:07"), expected, "slash form with seconds")
        XCTAssertEqual(parser.parse("03/04/2026 05:06"), local("MM/dd/yyyy HH:mm", "03/04/2026 05:06"))
        XCTAssertEqual(parser.parse(" 2026-03-04 "), local("yyyy-MM-dd", "2026-03-04"))
        let zoned = try XCTUnwrap(parser.parse("2026-03-04T05:06:07Z"))
        XCTAssertEqual(zoned.timeIntervalSince1970, 1_772_600_767, accuracy: 0.5)
        let fractional = try XCTUnwrap(parser.parse("2026-03-04T05:06:07.712Z"))
        XCTAssertEqual(fractional.timeIntervalSince(zoned), 0.712, accuracy: 0.01)
    }

    func testUnreadableTextIsNil() {
        let parser = DateParser()
        for text in ["", "   ", "not-a-date", "2026-13-45"] {
            XCTAssertNil(parser.parse(text), text)
        }
    }
}
