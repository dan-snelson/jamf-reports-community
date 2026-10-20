import XCTest
@testable import JamfReports

/// Fleet Drift from two `computers` snapshots. Every Mac is invented.
final class SnapshotFleetDriftTests: XCTestCase {

    private var roots: [URL] = []
    private let anchor = GoldenFleetClock.anchorNoon()
    private let iso = ISO8601DateFormatter()

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func at(_ dayOffset: Int, hour: Int = 12) -> Date {
        GoldenFleetClock.timestamp(dayOffset: dayOffset, hour: hour, minute: 0, relativeTo: anchor)
    }

    /// A Mac whose dates sit `daysOld` before `taken`, an hour clear of a day boundary.
    private func mac(
        _ id: Int?, serial: String? = nil, os: String = "26.0", daysOld: Double = 1,
        inventoryDaysOld: Double? = nil, taken: Date
    ) -> [String: Any] {
        func stamp(_ days: Double) -> String {
            iso.string(from: taken.addingTimeInterval(-days * 86_400 - 3_600))
        }
        var general: [String: Any] = ["name": "Mac-\(id ?? 0)-\(serial ?? "")",
                                      "lastCheckIn": stamp(daysOld),
                                      "reportDate": stamp(inventoryDaysOld ?? daysOld)]
        general["lastContact"] = NSNull()
        var item: [String: Any] = ["general": general, "operatingSystem": ["version": os]]
        if let id { item["id"] = String(id) }
        if let serial { item["hardware"] = ["serialNumber": serial] }
        return item
    }

    private func dashboard(
        _ yaml: String = "", files: [(Date, [[String: Any]])]
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        for (date, rows) in files {
            _ = try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: date, rows: rows)
        }
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir, workbook: Workbook())
    }

    private func texts(_ dash: CoreDashboard) throws -> [String] {
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        return sheet.dedupedCells.map {
            switch $0.value {
            case .string(let s): s
            case .int(let i): String(i)
            default: ""
            }
        }
    }

    /// The rows listed under `title`: everything up to the next section title.
    private func section(_ title: String, in dash: CoreDashboard) throws -> [String] {
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        let cells = sheet.dedupedCells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        let titles: Set = ["New Enrollments", "Departed Devices", "New Stale", "Recovered Stale",
                           "OS Changed"]
        guard let start = cells.firstIndex(where: { $0.col == 0 && $0.row > 0 && text($0.value) == title })
        else { return [] }
        let body = cells[(start + 1)...].prefix { !($0.col == 0 && titles.contains(text($0.value))) }
        return body.filter { $0.col == 0 && text($0.value) != "Name" }.map { text($0.value) }
    }

    private func text(_ value: CellValue) -> String {
        if case .string(let s) = value { return s }
        return ""
    }

    // MARK: - Joined, left, OS change

    func testJoinedLeftAndOSChangeAreFoundByJamfID() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, serial: "A1", taken: old), mac(2, serial: "A2", taken: old),
                         mac(3, serial: "A3", os: "26.0", taken: old)]),
            (new, [mac(1, serial: "A1", taken: new), mac(3, serial: "A3", os: "26.1.0", taken: new),
                         mac(4, serial: "A4", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-4-A4"])
        XCTAssertEqual(try section("Departed Devices", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-A2"])
        XCTAssertEqual(try section("OS Changed", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-3-A3"])
    }

    func testOSVersionSpellingsOfOneReleaseAreNotAChange() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, os: "26.7", taken: old)]),
            (new, [mac(1, os: "26.7.0", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("OS Changed", in: dash), ["No changes"])
    }

    func testSerialJoinsAMacWhoseRecordHasNoJamfID() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(nil, serial: "A1", taken: old)]),
            (new, [mac(7, serial: "A1", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertEqual(try section("Departed Devices", in: dash), ["No changes"])
    }

    func testMacWithNeitherIdentifierIsSkippedAndCounted() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, taken: old)]),
            (new, [mac(1, taken: new), mac(nil, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertTrue(try texts(dash).contains("1 Macs with no Jamf ID or serial left out"))
    }

    func testASerialTwoRecordsHoldIsNeitherJoinedNorLeft() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(nil, serial: "DUP", taken: old), mac(nil, serial: "DUP", taken: old),
                   mac(1, serial: "A1", taken: old)]),
            (new, [mac(nil, serial: "DUP", taken: new), mac(nil, serial: "DUP", taken: new),
                   mac(1, serial: "A1", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertEqual(try section("Departed Devices", in: dash), ["No changes"])
        XCTAssertTrue(try texts(dash).contains(
            "4 Macs whose Jamf ID or serial more than one record holds left out"))
    }

    // MARK: - Stale

    func testASnapshotWithoutDatesIsNotComparedForStaleness() throws {
        let (old, new) = (at(-1), at(0))
        let undated: [[String: Any]] = (1...3).map {
            ["id": String($0), "general": ["name": "Mac-\($0)-"],
             "operatingSystem": ["version": "26.0"]]
        }
        let dash = try dashboard(files: [
            (old, (1...3).map { mac($0, taken: old) }), (new, undated),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash), ["Not compared"])
        XCTAssertEqual(try section("Recovered Stale", in: dash), ["Not compared"])
        XCTAssertTrue(try texts(dash).contains(
            "Not compared: a snapshot has no check-in or inventory dates"))
    }

    func testStaleTransitionsUseTheCheckInAndInventoryBasis() throws {
        let (old, new) = (at(-1), at(0))
        let yaml = "thresholds:\n  stale_device_days: 30\n  stale_basis: [check_in, inventory]\n"
        let dash = try dashboard(yaml, files: [
            // 1: inventory goes quiet. 2: recovers. 3: checks in, never inventories, stays stale.
            (old, [mac(1, daysOld: 2, inventoryDaysOld: 2, taken: old),
                         mac(2, daysOld: 2, inventoryDaysOld: 40, taken: old),
                         mac(3, daysOld: 2, inventoryDaysOld: 40, taken: old)]),
            (new, [mac(1, daysOld: 2, inventoryDaysOld: 41, taken: new),
                         mac(2, daysOld: 2, inventoryDaysOld: 2, taken: new),
                         mac(3, daysOld: 2, inventoryDaysOld: 45, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash).filter { $0.hasPrefix("Mac-") }, ["Mac-1-"])
        XCTAssertEqual(try section("Recovered Stale", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-"])
    }

    func testCheckInAloneIgnoresAnOldInventoryDate() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, daysOld: 2, inventoryDaysOld: 2, taken: old)]),
            (new, [mac(1, daysOld: 2, inventoryDaysOld: 90, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash), ["No changes"])
    }

    // MARK: - Baseline choice

    func testBaselineIsTheNewestSnapshotOfAnEarlierDayNotAnEarlierFileOfTheSameDay() throws {
        let dash = try dashboard(files: [
            (at(-2), [mac(1, taken: at(-2)), mac(2, taken: at(-2))]),
            (at(0, hour: 6), [mac(1, taken: at(0, hour: 6)), mac(2, taken: at(0, hour: 6))]),
            (at(0, hour: 18), [mac(1, taken: at(0, hour: 18))]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("Departed Devices", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-"], "Mac 2 left after the day-before-yesterday snapshot")
    }

    func testSyncConflictCopyIsNotASnapshot() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, taken: old)]),
            (new, [mac(1, taken: new)]),
            // A provider's copy of the older file, named like a stamped snapshot with a suffix.
            (at(0, hour: 20), [mac(1, taken: new), mac(9, taken: new)]),
        ])
        let root = dash.dataDir.appendingPathComponent("computers")
        let copy = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted().last)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(copy),
            to: root.appendingPathComponent(copy.replacingOccurrences(of: ".json", with: " 2.json")))
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
    }

    func testALinkAtTheNewestSnapshotIsNotRead() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, serial: "A1", taken: old)]), (new, [mac(1, serial: "A1", taken: new)]),
        ])
        let folder = dash.dataDir.appendingPathComponent("computers")
        let newest = folder.appendingPathComponent(try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().last))
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: newest, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: newest, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try dash.writeFleetDrift())
        XCTAssertNil(dash.workbook.sheet(named: "Fleet Drift")?.dedupedCells.first)
    }

    func testNoEarlierDaySnapshotSkipsTheSheet() throws {
        let dash = try dashboard(files: [
            (at(0, hour: 6), [mac(1, taken: at(0, hour: 6))]),
            (at(0, hour: 18), [mac(1, taken: at(0, hour: 18))]),
        ])
        XCTAssertThrowsError(try dash.writeFleetDrift()) { XCTAssertTrue($0 is SheetSkippable) }
        XCTAssertNil(dash.workbook.sheet(named: "Fleet Drift"))
    }

    func testSheetIsPlannedAndTemplatesListIt() throws {
        let dash = CoreDashboard(config: try ConfigLoader.loadFromString(""), dataDir: URL(fileURLWithPath: "/nonexistent"),
                                 workbook: Workbook())
        XCTAssertTrue(dash.sheetPlan.map(\.name).contains(SheetID.fleetDrift.rawValue))
        for template: any ReportTemplate in [FullInstanceTemplate(), OperationalTemplate(), AssetTemplate()] {
            XCTAssertTrue(template.includedSheets.contains(.fleetDrift))
        }
    }
}
