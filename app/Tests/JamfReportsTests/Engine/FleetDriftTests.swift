import XCTest
@testable import JamfReports

final class FleetDriftTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetDriftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func baseConfig(staleDays: Int = 30) -> ReportConfig {
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        cols.operatingSystem = "OS Version"
        cols.lastCheckin = "Last Check-in"
        cols.department = "Department"
        config.columns = cols
        var t = ThresholdsConfig()
        t.staleDeviceDays = staleDays
        config.thresholds = t
        return config
    }

    private func recentDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func csvRow(
        name: String, serial: String, os: String = "14.0",
        checkin: String, department: String = "IT"
    ) -> CSVRow {
        [
            "Computer Name": name,
            "Serial Number": serial,
            "OS Version": os,
            "Last Check-in": checkin,
            "Department": department,
        ]
    }

    // MARK: - PriorCSVLoader

    func testPriorLoaderSkipsCurrentCSV() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let headers = "Computer Name,Serial Number,OS Version,Last Check-in,Department\n"
        let currentCSV = dir.appendingPathComponent("current.csv")
        try (headers + "Mac1,AAA,14.0,2024-01-01,IT\n").write(
            to: currentCSV, atomically: true, encoding: .utf8
        )
        // Copy same file to historical dir — should be skipped by hash check.
        let historical = dir.appendingPathComponent("historical", isDirectory: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: currentCSV,
                                         to: historical.appendingPathComponent("current.csv"))
        let result = PriorCSVLoader.load(historicalDir: historical, currentCSVURL: currentCSV)
        XCTAssertNil(result, "Should skip CSV with same hash as current")
    }

    func testPriorLoaderSkipsDifferentSchema() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("current.csv")
        try "Name,Serial\nMac1,AAA\n".write(to: current, atomically: true, encoding: .utf8)
        let historical = dir.appendingPathComponent("historical", isDirectory: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        // Different schema
        try "Name,Serial,Extra\nMac2,BBB,xyz\n".write(
            to: historical.appendingPathComponent("prior.csv"), atomically: true, encoding: .utf8
        )
        let result = PriorCSVLoader.load(historicalDir: historical, currentCSVURL: current)
        XCTAssertNil(result, "Should skip CSV with different column schema")
    }

    func testPriorLoaderReturnsMatchingPrior() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let headers = "Computer Name,Serial Number,OS Version,Last Check-in,Department\n"
        let current = dir.appendingPathComponent("current.csv")
        try (headers + "Mac1,AAA,14.0,2024-01-01,IT\n").write(
            to: current, atomically: true, encoding: .utf8
        )
        let historical = dir.appendingPathComponent("historical", isDirectory: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        try (headers + "Mac2,BBB,13.0,2023-12-01,IT\n").write(
            to: historical.appendingPathComponent("prior.csv"), atomically: true, encoding: .utf8
        )
        let result = PriorCSVLoader.load(historicalDir: historical, currentCSVURL: current)
        XCTAssertNotNil(result, "Should find a matching prior CSV")
        XCTAssertEqual(result?.label, "prior.csv")
        XCTAssertEqual(result?.rows.count, 1)
    }

    // MARK: - CSVParser.parseHeader (header-only parse used by PriorCSVLoader)

    func testParseHeaderMatchesFullParseHeaders() throws {
        let csvText = "Computer Name,Serial Number,OS Version\nMac1,AAA,15.0\nMac2,BBB,14.0\n"
        let data = Data(csvText.utf8)
        let headerOnly = CSVParser.parseHeader(data)
        let (fullHeaders, _) = try CSVParser.parse(data)
        XCTAssertEqual(headerOnly, fullHeaders,
                       "Header-only parse must match the header row from a full parse")
    }

    func testPriorLoaderSkipsSchemaMismatchThenReturnsMatchingCandidate() throws {
        // Guards the header-only pre-check added to PriorCSVLoader.load: a
        // schema-mismatched candidate must still be skipped (not just cheaply
        // rejected-but-silently-accepted), and a matching candidate elsewhere
        // in the directory must still be fully parsed and returned intact.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let headers = "Computer Name,Serial Number,OS Version,Last Check-in,Department\n"
        let current = dir.appendingPathComponent("current.csv")
        try (headers + "Mac1,AAA,14.0,2024-01-01,IT\n").write(
            to: current, atomically: true, encoding: .utf8
        )
        let historical = dir.appendingPathComponent("historical", isDirectory: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        try "Name,Serial,Extra\nMac2,BBB,xyz\n".write(
            to: historical.appendingPathComponent("mismatch.csv"), atomically: true, encoding: .utf8
        )
        try (headers + "Mac3,CCC,13.0,2023-11-01,IT\nMac4,DDD,13.0,2023-11-02,Ops\n").write(
            to: historical.appendingPathComponent("match.csv"), atomically: true, encoding: .utf8
        )
        let result = try XCTUnwrap(
            PriorCSVLoader.load(historicalDir: historical, currentCSVURL: current)
        )
        XCTAssertEqual(result.label, "match.csv")
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.first?["Computer Name"], "Mac3")
    }

    // MARK: - FleetDriftWriter: New Enrollments

    func testNewEnrollmentsDetected() {
        let config = baseConfig()
        let current = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 5)),
                       csvRow(name: "Mac2", serial: "BBB", checkin: recentDate(daysAgo: 3))]
        let prior   = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 10))]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }
        XCTAssertNotNil(ws)
        let strings = ws!.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("Mac2"), "New device Mac2 should appear in New Enrollments")
    }

    // MARK: - FleetDriftWriter: Departed Devices

    func testDepartedDevicesDetected() {
        let config = baseConfig()
        let current = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 5))]
        let prior   = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 10)),
                       csvRow(name: "Mac2", serial: "BBB", checkin: recentDate(daysAgo: 8))]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("Mac2"), "Departed Mac2 should appear in Departed Devices")
    }

    // MARK: - FleetDriftWriter: OS Changed

    func testOSChangedDetected() {
        let config = baseConfig()
        let current = [csvRow(name: "Mac1", serial: "AAA", os: "15.0", checkin: recentDate(daysAgo: 5))]
        let prior   = [csvRow(name: "Mac1", serial: "AAA", os: "14.0", checkin: recentDate(daysAgo: 10))]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("15.0") || strings.contains("14.0"),
                      "OS change should appear in OS Changed section")
    }

    // MARK: - FleetDriftWriter: New Stale

    func testNewStaleDetected() {
        let config = baseConfig(staleDays: 30)
        // Mac1: was active in prior, now stale
        let current = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 60))]
        let prior   = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 5))]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("Mac1"),
                      "Mac1 transitioning to stale should appear in the Fleet Drift sheet")
    }

    // MARK: - FleetDriftWriter: Compliance Changed

    func testComplianceChangedStatus() {
        var config = baseConfig()
        var comp = ComplianceConfig()
        comp.failuresCountColumn = "Failures"
        config.compliance = comp

        let current: [CSVRow] = [["Computer Name": "Mac1", "Serial Number": "AAA",
                                   "OS Version": "15.0", "Last Check-in": recentDate(daysAgo: 5),
                                   "Department": "IT", "Failures": "0"]]
        let prior: [CSVRow]   = [["Computer Name": "Mac1", "Serial Number": "AAA",
                                   "OS Version": "15.0", "Last Check-in": recentDate(daysAgo: 10),
                                   "Department": "IT", "Failures": "3"]]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("Recovered"), "Mac1 going from 3→0 failures should be 'Recovered'")
    }

    func testComplianceChangedNoteWhenNotConfigured() {
        let config = baseConfig()  // no compliance column configured
        let current = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 5))]
        let prior   = [csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 10))]
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: current, priorRows: prior,
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains(where: { $0.contains("not configured") }),
                      "Should show note when failures_count_column is not configured")
    }

    // MARK: - Serial case-insensitive comparison

    func testSerialsAreUppercasedForComparison() {
        let config = baseConfig()
        // current has lowercase serial, prior has uppercase — should be same device
        var curRow = csvRow(name: "Mac1", serial: "aaa", checkin: recentDate(daysAgo: 5))
        var priorRow = csvRow(name: "Mac1", serial: "AAA", checkin: recentDate(daysAgo: 10))
        // Overwrite serial field
        curRow["Serial Number"] = "aaa"
        priorRow["Serial Number"] = "AAA"
        let wb = Workbook()
        let writer = FleetDriftWriter(
            config: config, currentRows: [curRow], priorRows: [priorRow],
            priorLabel: "prior.csv", workbook: wb
        )
        writer.writeFleetDrift()
        let ws = wb.sheets.first { $0.name == "Fleet Drift" }!
        let strings = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        // Should not appear as new enrollment OR departed — they're the same device.
        XCTAssertFalse(strings.contains("New Enrollments") && strings.contains("Mac1"))
    }

    // MARK: - Fleet Drift absent when no prior snapshot

    func testFleetDriftSheetAbsentWhenNoPrior() {
        var config = baseConfig()
        config.charts = ChartsConfig()
        // historical_csv_dir not configured
        let csvData = Data("Computer Name,Serial Number\nMac1,AAA\n".utf8)
        let wb = Workbook()
        guard let dashboard = CSVDashboard(config: config, csvData: csvData, workbook: wb) else {
            XCTFail("CSVDashboard init failed"); return
        }
        let names = dashboard.sheetPlan.map { $0.name }
        XCTAssertFalse(names.contains("Fleet Drift"), "Fleet Drift should not appear without prior snapshot")
    }
    // MARK: - Folder resolution

    private let driftHeaders = "Computer Name,Serial Number,OS Version,Last Check-in,Department\n"

    /// A workspace under a test root, a current CSV beside it and one prior export in `folder`.
    private func driftFixture(
        configYAML: String, priorFolder: (URL) -> URL
    ) throws -> (config: ReportConfig, current: URL, workspace: URL) {
        let root = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let workspace = root.appendingPathComponent("driftprofile", isDirectory: true)
        let folder = priorFolder(workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try configYAML.write(to: workspace.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        try (driftHeaders + "Mac2,BBB,13.0,2023-12-01,IT\n").write(
            to: folder.appendingPathComponent("prior.csv"), atomically: true, encoding: .utf8)
        let current = root.appendingPathComponent("current.csv")
        try (driftHeaders + "Mac1,AAA,14.0,2024-01-01,IT\n").write(
            to: current, atomically: true, encoding: .utf8)
        var config = baseConfig()
        config.jamfCli = try JSONDecoder().decode(
            JamfCLIConfig.self, from: Data(#"{"profile":"driftprofile"}"#.utf8))
        var charts = ChartsConfig()
        charts.historicalCsvDir = ConfigLoader.rawValue(
            at: ["charts", "historical_csv_dir"],
            in: try ConfigLoader.rawMapping(fromYAML: configYAML)) as? String
        config.charts = charts
        return (config, current, workspace)
    }

    func testARelativeHistoricalDirIsTheWorkspacesFolderNotTheWorkingDirectory() throws {
        let fixture = try driftFixture(
            configYAML: "charts:\n  historical_csv_dir: snaps\n",
            priorFolder: { $0.appendingPathComponent("snaps", isDirectory: true) })
        let dashboard = try XCTUnwrap(CSVDashboard(
            config: fixture.config, csvData: try Data(contentsOf: fixture.current),
            workbook: Workbook(), currentCSVURL: fixture.current))
        XCTAssertEqual(dashboard.priorSnapshot?.label, "prior.csv")
    }

    func testAnAbsoluteHistoricalDirOutsideTheWorkspaceNeedsTheOptIn() throws {
        let outside = NSHomeDirectory() + "/jrc-drift-out-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }
        let fixture = try driftFixture(
            configYAML: "charts:\n  historical_csv_dir: \"\(outside)\"\n",
            priorFolder: { _ in URL(fileURLWithPath: outside, isDirectory: true) })
        XCTAssertNil(CSVDashboard.priorSnapshotDir(config: fixture.config))

        let optedIn = "output:\n  allow_absolute_paths: true\ncharts:\n"
            + "  historical_csv_dir: \"\(outside)\"\n"
        try optedIn
            .write(to: fixture.workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        XCTAssertEqual(CSVDashboard.priorSnapshotDir(config: fixture.config)?.path,
                       URL(fileURLWithPath: outside).resolvingSymlinksInPath().path)
    }

    func testAnUnconfirmedHistoricalDirOnASharedWorkspaceReadsTheDefaultFolder() throws {
        let outside = NSHomeDirectory() + "/jrc-drift-out-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }
        let yaml = "shared_workspace:\n  enabled: true\noutput:\n  allow_absolute_paths: true\n"
            + "charts:\n  historical_csv_dir: \"\(outside)\"\n"
        let fixture = try driftFixture(
            configYAML: yaml,
            priorFolder: { _ in URL(fileURLWithPath: outside, isDirectory: true) })
        // First sight pins an absolute folder as unconfirmed, so it reads as the default.
        XCTAssertEqual(CSVDashboard.priorSnapshotDir(config: fixture.config)?.lastPathComponent,
                       "snapshots")
        try SharedConfigPin.confirm(
            profile: "driftprofile",
            drifts: SharedConfigPin.check(profile: "driftprofile").drifts)
        XCTAssertEqual(CSVDashboard.priorSnapshotDir(config: fixture.config)?.path,
                       URL(fileURLWithPath: outside).resolvingSymlinksInPath().path)
    }
}
