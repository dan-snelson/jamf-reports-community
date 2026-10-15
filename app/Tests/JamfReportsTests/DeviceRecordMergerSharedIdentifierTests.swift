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

    /// The cap must not let a name join two Macs the identifiers keep apart: the row's serial is
    /// the placeholder, the one Mac with its name has a real serial, so it is another Mac.
    func testARowLeftWithOnlyItsNameNeverJoinsAMacWhoseSerialDiffers() {
        var merger = merger(computers: cap + 1)
        merger.upsert(computer(9_001, serial: "C02REALSERIAL"))
        let before = merger.records.count

        merger.upsert(compliance("Fixture-9001", serial: placeholder, days: 77))

        XCTAssertEqual(merger.records.count, before + 1, "the row is its own Mac")
        let real = merger.records.first { $0.serial == "C02REALSERIAL" }
        XCTAssertNil(real?.daysSinceContact, "the real Mac keeps its own data")
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

    // MARK: Shared names

    private func namedComputer(_ id: Int, name: String) -> DeviceInventoryRecord {
        let item: [String: Any] = [
            "id": String(id), "general": ["name": name],
            "hardware": ["serialNumber": "FXTR\(id)"],
        ]
        return DeviceInventoryService.recordFromComputer(item, source: "computers.json")
    }

    /// Several Macs on one name stay several, and a name-only row cannot pick one of them.
    func testManyMacsOnOneNameStayApartAndANameOnlyRowIsLeftOut() {
        var merger = DeviceRecordMerger()
        for id in 1...120 { merger.upsert(namedComputer(id, name: "localhost")) }

        merger.upsert(DeviceInventoryService.recordFromCompliance(
            ["name": "localhost", "days_since_contact": "9"], source: "device-compliance.json"))

        XCTAssertEqual(merger.records.count, 120)
        XCTAssertEqual(merger.leftOutRows["device-compliance.json"], 1)
        XCTAssertTrue(merger.records.allSatisfy { $0.daysSinceContact != 9 })
    }

    /// One name on thousands of Macs (a default hostname) must not make the merge quadratic.
    func testTensOfThousandsOfRecordsOnOneNameMergeInReasonableTime() {
        let count = 20_000
        let start = Date()
        var merger = DeviceRecordMerger()
        for id in 1...count { merger.upsert(namedComputer(id, name: "localhost")) }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(merger.records.count, count)
        XCTAssertLessThan(elapsed, 6, "took \(elapsed) s")
    }

    // MARK: Row ids

    private func csvRow(_ n: Int, serial: String) -> DeviceInventoryRecord {
        DeviceInventoryService.recordFromCSV(
            ["Computer Name": "Row-\(n)", "Serial Number": serial], source: "inventory.csv")
    }

    /// Rows that share a placeholder serial and carry no Jamf ID, management ID or UDID all
    /// start from one id, so each needs a suffix; finding it must not scan every earlier one.
    func testThousandsOfRowsWithNoStrongIdentifierGetIDsInReasonableTime() {
        let count = 10_000
        let rows = (1...count).map { csvRow($0, serial: placeholder) }
        var merger = merger(computers: cap + 1)
        let start = Date()
        for row in rows { merger.upsert(row) }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(merger.records.count, cap + 1 + count)
        XCTAssertEqual(Set(merger.records.map(\.id)).count, cap + 1 + count)
        XCTAssertLessThan(elapsed, 5, "took \(elapsed) s")
    }

    /// The ids are the ones the linear probe handed out. The first Macs took the base and `#2`
    /// to `#51` from their Jamf IDs, so the rows with none count up from `#52`.
    func testSuffixesCountUpFromTheFirstFreeNumberInArrivalOrder() {
        var merger = merger(computers: cap + 1)
        let base = merger.records[0].id
        for n in 1...6 { merger.upsert(csvRow(n, serial: placeholder)) }

        XCTAssertEqual(merger.records.dropFirst(cap + 1).map(\.id),
                       (52...57).map { "\(base)#\($0)" })
    }

    /// A row whose own id already is a suffix the count reaches is skipped over, as before.
    func testASuffixAnotherRowAlreadyUsesIsSkipped() {
        var merger = merger(computers: cap + 1)
        let base = merger.records[0].id
        merger.upsert(csvRow(1, serial: placeholder))
        var taken = csvRow(2, serial: "OTHER")
        taken.id = "\(base)#54"
        merger.upsert(taken)
        for n in 3...5 { merger.upsert(csvRow(n, serial: placeholder)) }

        XCTAssertEqual(merger.records.dropFirst(cap + 1).map(\.id),
                       [52, 54, 53, 55, 56].map { "\(base)#\($0)" })
    }
}
