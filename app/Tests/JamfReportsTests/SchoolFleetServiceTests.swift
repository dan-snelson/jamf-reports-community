import XCTest
@testable import JamfReports

final class SchoolFleetServiceTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("school-fleet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func write(_ json: String, kind: String, stamp: String = "20261019T080000") throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(kind)_\(stamp).json"))
    }

    func test_noSnapshots_isNotDetected() {
        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertNil(snapshot.collectedAt)
    }

    func test_devices_readJamfCLIShape_andLeaveTrashOut() throws {
        try write("""
        [{"name":"Cart iPad 01","serialNumber":"SER001","model":"iPad (10th generation)",
          "os":"iPadOS 27.0.1","isManaged":true,"isSupervised":true,
          "lastCheckin":"2026-10-18 09:00:00","inTrash":false,"udid":"u1"},
         {"name":"Lab Mac 02","serialNumber":"SER002","model":"MacBook Air",
          "os":"macOS 26.6.2","isManaged":false,"isSupervised":false,
          "lastCheckin":"2026-08-01 09:00:00","inTrash":false},
         {"name":"Old iPad","serialNumber":"SER003","os":"iPadOS 18.1","inTrash":true},
         {"name":"No dates","serialNumber":"SER004","os":"iOS 27.0","isManaged":"yes"}]
        """, kind: SchoolFleetService.devicesKind)

        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.devices.map(\.serial), ["SER001", "SER002", "SER004"])
        XCTAssertEqual(snapshot.trashedCount, 1)
        XCTAssertEqual(snapshot.managedCount, 1)
        XCTAssertEqual(snapshot.unmanagedCount, 1, "a non-boolean managed flag is unknown")
        XCTAssertEqual(snapshot.supervisedCount, 1)
        XCTAssertEqual(snapshot.devices[0].id, "u1")
        XCTAssertEqual(snapshot.devices[1].id, "SER002", "the serial stands in for a missing udid")
        XCTAssertEqual(snapshot.devices.map(\.platform), ["iPadOS", "macOS", "iOS"])

        let now = DateParser().parse("2026-10-19 09:00:00")!
        XCTAssertEqual(snapshot.staleCount(atDays: 30, now: now), 1)
        XCTAssertFalse(snapshot.devices[2].isStale(atDays: 30, now: now),
                       "an unknown check-in is not stale")
    }

    func test_staleIsMoreThanTheThreshold() throws {
        let now = DateParser().parse("2026-10-31 09:00:00")!
        let device = SchoolFleetService.device(
            from: ["lastCheckin": "2026-10-01 09:00:00"], index: 0)
        XCTAssertFalse(device.isStale(atDays: 30, now: now), "exactly 30 days is not stale")
        XCTAssertTrue(device.isStale(atDays: 29, now: now))
    }

    func test_overviewAndDEP_rows() throws {
        try write("""
        [{"section":"Devices","resource":"Devices","value":"42"},
         {"section":"People","resource":"Users","value":"310"},
         {"section":"x","value":"no resource"}]
        """, kind: SchoolFleetService.overviewKind)
        try write("""
        [{"serialNumber":"DEP1","deviceName":"","model":"iPad","status":"assigned",
          "profileName":"Cart profile"}]
        """, kind: SchoolFleetService.depDevicesKind, stamp: "20261019T090000")

        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertEqual(snapshot.overview.map(\.resource), ["Devices", "Users"])
        XCTAssertEqual(snapshot.overview[1].value, "310")
        XCTAssertEqual(snapshot.depDevices.first?.profile, "Cart profile")
        XCTAssertNil(snapshot.devicesDate)
        XCTAssertEqual(snapshot.collectedAt, snapshot.depDate)
    }

    /// A count of 0 or 1 printed as a JSON number is a number, not a boolean.
    func test_overviewNumbersZeroAndOneReadAsText() throws {
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        [{"resource":"iBeacons","value":0},{"resource":"Classes","value":1},
         {"resource":"Flag","value":true}]
        """.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap(SchoolFleetService.overviewRow).map(\.value), ["0", "1", ""])
    }

    func test_platformCounts_largestFirst() {
        var snapshot = SchoolFleetService.Snapshot()
        snapshot.devices = ["iOS 27", "iPadOS 27", "iPadOS 26", "macOS 26"].enumerated().map {
            SchoolFleetService.device(from: ["os": $1], index: $0)
        }
        XCTAssertEqual(snapshot.platformCounts.map(\.platform), ["iPadOS", "iOS", "macOS"])
        XCTAssertEqual(snapshot.platformCounts.first?.count, 2)
    }

    func test_tabs_schoolDevicesOnlyOnSchool() {
        XCTAssertTrue(TabVisibility().limited(toSchool: true).isVisible(.schoolDevices))
        XCTAssertFalse(TabVisibility().limited(toSchool: false).isVisible(.schoolDevices))
        XCTAssertFalse(TabVisibility().limited(toSchool: true).isVisible(.devices))
    }
}
