import XCTest
@testable import JamfReports

final class DeviceCorrelationTests: XCTestCase {

    private func pro(
        _ id: String, udid: String? = nil, serial: String = ""
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: id, source: "test")
        record.name = "Mac"
        record.jamfID = id
        record.udid = udid
        record.serial = serial
        return record
    }

    private func probe(udid: String? = nil, serial: String = "") -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "p", source: "test")
        record.udid = udid
        record.serial = serial
        return record
    }

    private func protectRow(
        uuid: String?, serial: String?, host: String? = "host"
    ) throws -> ProtectComputerRow {
        var object: [String: Any] = [:]
        object["uuid"] = uuid
        object["serial"] = serial
        object["hostname"] = host
        let data = try JSONSerialization.data(withJSONObject: [object])
        return try XCTUnwrap(JSONDecoder().decode([ProtectComputerRow].self, from: data).first)
    }

    func testUDIDMatchesIgnoringCase() {
        let correlation = DeviceCorrelation(records: [pro("1", udid: "ABC-123")])
        XCTAssertEqual(correlation.match(probe(udid: " abc-123 ")), .matched(0, via: .udid))
    }

    func testSerialAloneMatches() {
        let correlation = DeviceCorrelation(records: [pro("1", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(serial: "c02abc")), .matched(0, via: .serial))
    }

    func testSameSerialDifferentUDIDIsUnmatched() {
        let correlation = DeviceCorrelation(records: [pro("1", udid: "AAA", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(udid: "BBB", serial: "C02ABC")), .unmatched)
    }

    func testOneSerialOnTwoRecordsIsAmbiguous() {
        let correlation = DeviceCorrelation(
            records: [pro("1", serial: "C02ABC"), pro("2", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(serial: "C02ABC")), .ambiguous(2))
    }

    func testStrongIdentifierBeatsSerialCandidate() {
        let correlation = DeviceCorrelation(
            records: [pro("1", udid: "AAA"), pro("2", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(udid: "AAA", serial: "C02ABC")),
                       .matched(0, via: .udid))
    }

    func testNoIdentifierWhenOnlyAHostnameIsKnown() throws {
        let row = try protectRow(uuid: nil, serial: nil, host: "Mac")
        let result = ProtectProCorrelation.build(protect: [row], pro: [pro("1", serial: "X")])
        XCTAssertEqual(result.noIdentifier, 1)
        XCTAssertEqual(result.matched, 0)
        XCTAssertTrue(result.notInPro.isEmpty)
    }

    func testPlaceholderSerialOverTheCapJoinsNothing() {
        let cap = DeviceRecordMerger.maxRecordsPerSharedIdentifier
        let records = (0...cap).map { pro("\($0)", serial: "0") }
        XCTAssertEqual(DeviceCorrelation(records: records).match(probe(serial: "0")), .unmatched)
    }

    func testProWithoutProtectIsWhatNoMatchedRowClaimed() throws {
        let rows = [
            try protectRow(uuid: "AAA", serial: nil),
            try protectRow(uuid: "ZZZ", serial: "NOPE"),
            try protectRow(uuid: nil, serial: nil),
            try protectRow(uuid: nil, serial: "DUP"),
        ]
        let records = [
            pro("1", udid: "aaa"), pro("2", udid: "BBB", serial: "C02B"),
            pro("3", serial: "DUP"), pro("4", serial: "DUP"),
        ]
        let result = ProtectProCorrelation.build(protect: rows, pro: records)
        XCTAssertEqual(result.protectCount, 4)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.notInPro.count, 1)
        XCTAssertEqual(result.ambiguous, 1)
        XCTAssertEqual(result.noIdentifier, 1)
        XCTAssertEqual(result.proWithoutProtect.map(\.jamfID), ["2", "3", "4"])
    }
}
