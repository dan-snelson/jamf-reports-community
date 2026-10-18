import Foundation
import XCTest
@testable import JamfReports

final class CollectedEACandidatesTests: XCTestCase {

    private func rows(_ ea: String, _ values: [String]) -> [EAResultRow] {
        values.enumerated().map { index, value in
            decodeRow(["definition_id": "1", "device": "Mac-\(index)", "ea_name": ea, "value": value])
        }
    }

    private func decodeRow(_ json: [String: String]) -> EAResultRow {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(EAResultRow.self, from: data)
    }

    private func definitions(_ items: [(String, String)]) -> [ExtensionAttribute] {
        let json = items.enumerated().map {
            ["id": "\($0.offset)", "name": $0.element.0, "dataType": $0.element.1, "enabled": true]
                as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode([ExtensionAttribute].self, from: data)
    }

    private func candidate(
        _ name: String, rows: [EAResultRow], defs: [(String, String)] = [],
        tracked: Set<String> = []
    ) throws -> CollectedEACandidate {
        let all = CollectedEACandidates.build(
            rows: rows, definitions: definitions(defs), tracked: tracked)
        return try XCTUnwrap(all.first { $0.name == name })
    }

    func test_dateDefinitionIsDateEvenWithoutValues() throws {
        let c = try candidate("Cert Expiry", rows: [], defs: [("Cert Expiry", "DATE")])
        XCTAssertEqual(c.type, "date")
        XCTAssertTrue(c.hasNoValues)
    }

    func test_integerFitsPercentageOrFallsBackToText() throws {
        let pct = try candidate("Disk Used", rows: rows("Disk Used", ["12", "88", "100"]),
                                defs: [("Disk Used", "INTEGER")])
        XCTAssertEqual(pct.type, "percentage")
        let big = try candidate("Uptime", rows: rows("Uptime", ["12", "4000"]),
                                defs: [("Uptime", "INTEGER")])
        XCTAssertEqual(big.type, "text")
    }

    func test_stringGuessesFromValuesNotName() throws {
        let boolean = try candidate("Enrolled Via DEP",
            rows: rows("Enrolled Via DEP", ["Yes", "No", "Yes"]), defs: [("Enrolled Via DEP", "STRING")])
        XCTAssertEqual(boolean.type, "boolean", "the name must not make it a date")
        XCTAssertEqual(boolean.sampleValue, "Yes", "most common value")
        XCTAssertEqual(boolean.distinctValueCount, 2)
        XCTAssertEqual(boolean.valueCount, 3)
        let version = try candidate("Agent", rows: rows("Agent", ["5.7.6", "5.7.6"]))
        XCTAssertEqual(version.type, "version")
        let text = try candidate("Owner", rows: rows("Owner", ["a", "b", "c"]))
        XCTAssertEqual(text.type, "text")
    }

    func test_definitionWithNoRowsIsFlagged() throws {
        let c = try candidate("Unused", rows: rows("Other", ["x"]), defs: [("Unused", "STRING")])
        XCTAssertTrue(c.hasNoValues)
        XCTAssertEqual(c.type, "text")
        XCTAssertEqual(c.proposal.column, "Unused")
    }

    func test_alreadyTrackedIsCaseInsensitive() throws {
        let c = try candidate("FileVault", rows: rows("FileVault", ["Yes"]), tracked: ["filevault"])
        XCTAssertTrue(c.alreadyTracked)
        let other = try candidate("SIP", rows: rows("SIP", ["Yes"]), tracked: ["filevault"])
        XCTAssertFalse(other.alreadyTracked)
    }

    func test_blankValuesDoNotCount() throws {
        let c = try candidate("Mixed", rows: rows("Mixed", ["", "  ", "ok"]))
        XCTAssertEqual(c.valueCount, 1)
        XCTAssertEqual(c.sampleValues, ["ok"])
    }

    func test_noDeviceNameReachesTheCandidate() throws {
        let all = CollectedEACandidates.build(
            rows: rows("FileVault", ["Yes", "No"]), definitions: [], tracked: [])
        let text = String(describing: all)
        XCTAssertFalse(text.contains("Mac-"), "device names must not be carried")
    }

    func test_loadReadsTheNewestSnapshotByFilenameStamp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collected-ea-\(UUID().uuidString)", isDirectory: true)
        let results = dir.appendingPathComponent("ea-results", isDirectory: true)
        let defs = dir.appendingPathComponent("computer-extension-attributes", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: defs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, _ ea: String, in folder: URL) throws {
            let row = #"[{"definition_id":"1","device":"Mac-1","ea_name":"\#(ea)","value":"Yes"}]"#
            try row.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("ea-results_20260101T000000.json", "Old EA", in: results)
        try write("ea-results_20260301T000000.json", "New EA", in: results)
        // A sync conflict copy of the older file must not win on its fresh mtime.
        try write("ea-results_20260101T000000 2.json", "Conflict EA", in: results)
        try #"[{"id":"9","name":"Declared","dataType":"STRING","enabled":true}]"#.write(
            to: defs.appendingPathComponent("computer-extension-attributes_20260301T000000.json"),
            atomically: true, encoding: .utf8)

        let names = CollectedEACandidates.load(dataDir: dir, tracked: []).map(\.name)
        XCTAssertEqual(names, ["Declared", "New EA"])
    }
}
