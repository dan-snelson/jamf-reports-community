import Foundation
import XCTest
@testable import JamfReports

/// An identifier value on more than `maxRecordsPerSharedIdentifier` records is a placeholder
/// (a serial of `0`): it must not join rows, and it must not make the merge quadratic.
/// Fixtures are synthetic.
final class DeviceRecordMergerSharedIdentifierTests: XCTestCase {

    private let placeholder = "0000000000"
    private let cap = DeviceRecordMerger.maxRecordsPerSharedIdentifier

    private func computer(_ id: Int, serial: String) -> DeviceInventoryRecord {
        let item: [String: Any] = [
            "id": String(id), "general": ["name": "Fixture-\(id)"],
            "hardware": ["serialNumber": serial],
        ]
        return DeviceInventoryService.recordFromComputer(item, source: "computers.json")
    }

    private func compliance(_ name: String, serial: String, days: Int = 40) -> DeviceInventoryRecord {
        let item: [String: Any] = [
            "name": name, "serial": serial, "days_since_contact": String(days),
        ]
        return DeviceInventoryService.recordFromCompliance(item, source: "device-compliance.json")
    }

    private func merger(computers count: Int) -> DeviceRecordMerger {
        var merger = DeviceRecordMerger()
        for id in 1...count { merger.upsert(computer(id, serial: placeholder)) }
        return merger
    }

    func testMacsSharingAPlaceholderSerialStayApart() {
        let count = cap + 70
        let merger = merger(computers: count)

        XCTAssertEqual(merger.records.count, count)
        XCTAssertEqual(Set(merger.records.map(\.id)).count, count)
        XCTAssertTrue(merger.records.allSatisfy { $0.serial == placeholder },
                      "the placeholder stays on every record")
        XCTAssertTrue(merger.leftOutRows.isEmpty)
    }

    func testARowWhoseOnlyIdentifierIsThePlaceholderJoinsByItsName() {
        var merger = merger(computers: cap + 70)
        let before = merger.records.count

        merger.upsert(compliance("Fixture-100", serial: placeholder, days: 40))

        XCTAssertEqual(merger.records.count, before)
        XCTAssertEqual(merger.records.first { $0.name == "Fixture-100" }?.daysSinceContact, 40)
        XCTAssertEqual(merger.records.filter { $0.daysSinceContact == 40 }.count, 1,
                       "no other Mac takes the row")
    }

    func testARowWithAnUnknownNameAndThePlaceholderIsItsOwnMac() {
        var merger = merger(computers: cap + 1)

        merger.upsert(compliance("Fixture-Unknown", serial: placeholder))

        XCTAssertEqual(merger.records.count, cap + 2)
        XCTAssertTrue(merger.leftOutRows.isEmpty)
    }

    func testARowStillJoinsThroughAnotherIdentifierBesideThePlaceholder() {
        var merger = merger(computers: cap + 70)
        let before = merger.records.count
        let row = DeviceInventoryService.recordFromCSV(
            ["Computer Name": "Renamed", "Serial Number": placeholder, "Jamf ID": "120"],
            source: "inventory.csv")

        merger.upsert(row)

        XCTAssertEqual(merger.records.count, before)
        XCTAssertEqual(merger.records.filter { $0.source.contains("inventory.csv") }.count, 1)
    }

    /// At the cap the serial still joins, as it always did: a row with a name no record has,
    /// fitting all of them, is left out because nothing says which Mac it is.
    func testAValueOnExactlyTheCapOfRecordsStillJoins() {
        var merger = merger(computers: cap)

        merger.upsert(compliance("Fixture-Unknown", serial: placeholder))
        XCTAssertEqual(merger.records.count, cap)
        XCTAssertEqual(merger.leftOutRows["device-compliance.json"], 1)

        merger.upsert(compliance("Fixture-7", serial: placeholder, days: 9))
        XCTAssertEqual(merger.records.first { $0.name == "Fixture-7" }?.daysSinceContact, 9)
    }

    /// Thousands of records on one serial: a quadratic merge takes minutes here, a linear one
    /// well under the limit, which is generous so a slow CI runner does not trip it.
    func testThousandsOfRecordsOnOneSerialMergeInReasonableTime() {
        let count = 4_500
        let start = Date()
        var merger = DeviceRecordMerger()
        for id in 1...count { merger.upsert(computer(id, serial: placeholder)) }
        for id in stride(from: 1, through: count, by: 3) {
            merger.upsert(compliance("Fixture-\(id)", serial: placeholder, days: 5))
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(merger.records.count, count)
        XCTAssertEqual(merger.records.filter { $0.daysSinceContact == 5 }.count, count / 3)
        XCTAssertLessThan(elapsed, 5, "took \(elapsed) s")
    }
}
