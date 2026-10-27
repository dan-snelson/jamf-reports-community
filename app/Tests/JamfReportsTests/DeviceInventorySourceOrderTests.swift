import Foundation
import XCTest
@testable import JamfReports

/// #290: a Mac first seen as an unenrolled "DEP - <serial>" record kept a 1970 check-in after it
/// enrolled, because every field kept the first non-empty value. The merge keeps the newer
/// date label whichever source comes first.
final class DeviceInventorySourceOrderTests: XCTestCase {

    private func record(lastContact: String, lastInventory: String = "") -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "SER1", source: "test")
        record.lastContact = lastContact
        record.lastInventory = lastInventory
        return record
    }

    func testMergeKeepsTheNewerDateLabelInEitherOrder() {
        let old = "1970-01-01 00:00:00"
        let new = "2026-10-15T08:00:00Z"
        var first = record(lastContact: old, lastInventory: new)
        first.merge(record(lastContact: new, lastInventory: old))
        XCTAssertEqual(first.lastContact, new)
        XCTAssertEqual(first.lastInventory, new)

        var second = record(lastContact: new)
        second.merge(record(lastContact: old))
        XCTAssertEqual(second.lastContact, new)
    }

    func testMergePrefersAReadableDateOverText() {
        var unreadableFirst = record(lastContact: "Never")
        unreadableFirst.merge(record(lastContact: "2026-10-15 08:00:00"))
        XCTAssertEqual(unreadableFirst.lastContact, "2026-10-15 08:00:00")

        var readableFirst = record(lastContact: "2026-10-15 08:00:00")
        readableFirst.merge(record(lastContact: "Never"))
        XCTAssertEqual(readableFirst.lastContact, "2026-10-15 08:00:00")
    }

    func testMergeKeepsTheFirstLabelWhenNeitherIsADate() {
        var text = record(lastContact: "Never")
        text.merge(record(lastContact: "Unknown"))
        XCTAssertEqual(text.lastContact, "Never")

        var blank = record(lastContact: "")
        blank.merge(record(lastContact: "Unknown"))
        XCTAssertEqual(blank.lastContact, "Unknown")
    }
}
