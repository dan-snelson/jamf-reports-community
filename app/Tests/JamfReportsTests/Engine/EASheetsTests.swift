import Foundation
import XCTest
@testable import JamfReports

/// Custom EA tabs and the EA Warnings tab, written from the `ea-results` and
/// `computer-extension-attributes` snapshots instead of a CSV.
final class EASheetsTests: XCTestCase {

    private var dataDir: URL!
    private var saved: String?

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-easheets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // generate writes beside the workbook; keep that out of a real workspace.
        saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", dataDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
        else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Helpers

    private func snapshot(_ kind: String, _ json: Any) throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent("\(kind)_20261004T100000.json"))
    }

    private func results(_ rows: [(device: String, ea: String, value: String)]) throws {
        try snapshot("ea-results", rows.map {
            ["definition_id": "1", "device": $0.device, "ea_name": $0.ea, "value": $0.value]
        })
    }

    private func write(_ eas: [CustomEAConfig]) throws -> (Workbook, [String]) {
        var config = ReportConfig()
        config.customEas = eas
        let workbook = Workbook()
        let sheets = try XCTUnwrap(EASheets.load(
            config: config, workbook: workbook, dataDir: dataDir))
        return (workbook, sheets.writeAll(sheets: SheetsConfig()))
    }

    /// Cell text by row then column; numbers as text.
    private func grid(_ workbook: Workbook, _ tab: String) throws -> [[Int: String]] {
        let sheet = try XCTUnwrap(workbook.sheet(named: tab), "no tab \(tab)")
        var rows: [Int: [Int: String]] = [:]
        for cell in sheet.dedupedCells {
            switch cell.value {
            case .string(let text): rows[cell.row, default: [:]][cell.col] = text
            case .int(let number): rows[cell.row, default: [:]][cell.col] = String(number)
            case .double(let number): rows[cell.row, default: [:]][cell.col] = "\(number)"
            default: break
            }
        }
        return rows.sorted { $0.key < $1.key }.map(\.value)
    }

    private func row(_ grid: [[Int: String]], _ first: String) throws -> [Int: String] {
        try XCTUnwrap(grid.first { $0[0] == first }, "no row \(first) in \(grid)")
    }

    // MARK: - The five types

    func testBooleanTabCountsTrueOtherAndBlank() throws {
        try results([("A", "FV", "Encrypted"), ("B", "FV", "Encrypted"),
                     ("C", "FV", "Not Encrypted"), ("D", "FV", "  ")])
        let (wb, written) = try write([
            CustomEAConfig(name: "FileVault", column: "FV", type: .boolean, trueValue: "encrypted"),
        ])
        XCTAssertEqual(written, ["FileVault"])
        let grid = try grid(wb, "FileVault")
        XCTAssertEqual(try row(grid, "encrypted")[1], "2", "true_value is matched ignoring case")
        XCTAssertEqual(try row(grid, "Other")[1], "1")
        XCTAssertEqual(try row(grid, "Unknown/Blank")[1], "1")
    }

    func testPercentageTabGradesAgainstTheThresholds() throws {
        try results([("A", "Disk", "95"), ("B", "Disk", "85"), ("C", "Disk", "50")])
        let (wb, _) = try write([
            CustomEAConfig(name: "Disk", column: "Disk", type: .percentage,
                           warningThreshold: 80, criticalThreshold: 90),
        ])
        let grid = try grid(wb, "Disk")
        XCTAssertEqual(try row(grid, "95")[2], "Critical")
        XCTAssertEqual(try row(grid, "85")[2], "Warning")
        XCTAssertEqual(try row(grid, "50")[2], "OK")
    }

    func testVersionTabMarksCurrentAndSortsNewestFirst() throws {
        try results([("A", "OS", "15.7"), ("B", "OS", "26.1"), ("C", "OS", "26.1")])
        let (wb, _) = try write([
            CustomEAConfig(name: "OS", column: "OS", type: .version, currentVersions: ["26"]),
        ])
        let grid = try grid(wb, "OS")
        let versions = grid.compactMap { $0[0] }.filter { $0.first?.isNumber == true }
        XCTAssertEqual(versions, ["26.1", "15.7"])
        XCTAssertEqual(try row(grid, "26.1")[1], "2")
        XCTAssertEqual(try row(grid, "26.1")[2], "Current")
        XCTAssertEqual(try row(grid, "15.7")[2], "Outdated")
    }

    func testTextTabCountsValuesAndKeepsAMultiLineValueWhole() throws {
        let multi = "line one\nline two"
        try results([("A", "Notes", multi), ("B", "Notes", multi), ("C", "Notes", "plain"),
                     ("D", "Notes", "plain"), ("E", "Notes", "plain"), ("F", "Notes", "")])
        let (wb, _) = try write([CustomEAConfig(name: "Notes", column: "Notes", type: .text)])
        let grid = try grid(wb, "Notes")
        XCTAssertEqual(try row(grid, "plain")[1], "3")
        XCTAssertEqual(try row(grid, multi)[1], "2", "one row, not split at the newline")
        XCTAssertEqual(try row(grid, "(blank)")[1], "1")
    }

    func testDateTabFillsSerialsFromAUniqueNameAndLeavesAnAmbiguousOneBlank() throws {
        try results([("Mac-1", "Cert", "2000-01-01 00:00:00"),
                     ("Mac-2", "Cert", "2999-01-01 00:00:00"),
                     ("Twin", "Cert", "2999-01-01 00:00:00")])
        try snapshot("computers", [
            ["id": 1, "general": ["name": "Mac-1"], "hardware": ["serialNumber": "SER1"]],
            ["id": 2, "general": ["name": "mac-2 "], "hardware": ["serialNumber": "SER2"]],
            ["id": 3, "general": ["name": "Twin"], "hardware": ["serialNumber": "SER3"]],
            ["id": 4, "general": ["name": "Twin"], "hardware": ["serialNumber": "SER4"]],
        ])
        let (wb, _) = try write([CustomEAConfig(name: "Cert", column: "Cert", type: .date)])
        let grid = try grid(wb, "Cert")
        XCTAssertEqual(try row(grid, "Mac-1")[1], "SER1")
        XCTAssertEqual(try row(grid, "Mac-1")[4], "Expired")
        XCTAssertEqual(try row(grid, "Mac-2")[1], "SER2", "names join ignoring case and padding")
        XCTAssertEqual(try row(grid, "Mac-2")[4], "OK")
        XCTAssertEqual(try row(grid, "Twin")[1] ?? "", "",
                       "two Macs share the name, so no serial is guessed")
    }

    // MARK: - Matching

    func testEANameMatchesIgnoringCaseAndPadding() throws {
        try results([("A", "FileVault Status", "Encrypted")])
        let (_, written) = try write([
            CustomEAConfig(name: "FV", column: "  FILEVAULT status ", type: .text),
        ])
        XCTAssertEqual(written, ["FV"])
    }

    // MARK: - EA Warnings

    func testWarningsNameAnUndefinedAndAnEmptyEA() throws {
        try results([("A", "Present", "x")])
        try snapshot("computer-extension-attributes", [
            ["id": "1", "name": "Present", "dataType": "STRING", "enabled": true],
            ["id": "2", "name": "Empty One", "dataType": "STRING", "enabled": true],
        ])
        let (wb, written) = try write([
            CustomEAConfig(name: "Has Rows", column: "present", type: .text),
            CustomEAConfig(name: "Empty", column: "empty one", type: .text),
            CustomEAConfig(name: "Typo", column: "Presnt", type: .text),
            CustomEAConfig(name: "Blank", column: " ", type: .text),
        ])
        XCTAssertEqual(written, ["Has Rows", "EA Warnings"])
        let grid = try grid(wb, "EA Warnings")
        XCTAssertEqual(try row(grid, "Empty")[2], "Defined in Jamf Pro, no values collected")
        XCTAssertEqual(try row(grid, "Typo")[2], "Not defined in Jamf Pro")
        XCTAssertEqual(try row(grid, "Blank")[2], "No column configured")
    }

    func testNoWarningsTabWhenEveryEAHasRows() throws {
        try results([("A", "One", "x")])
        let (_, written) = try write([CustomEAConfig(name: "One", column: "One", type: .text)])
        XCTAssertEqual(written, ["One"])
    }

    // MARK: - Which source speaks

    func testNothingCollectedMeansNoTabs() throws {
        var config = ReportConfig()
        config.customEas = [CustomEAConfig(name: "One", column: "One", type: .text)]
        XCTAssertNil(EASheets.load(config: config, workbook: Workbook(), dataDir: dataDir),
                     "with no EA data at all there is nothing to say")
    }

    func testDefinitionsAloneWarn() throws {
        try snapshot("computer-extension-attributes", [["id": "1", "name": "One"]])
        let (_, written) = try write([CustomEAConfig(name: "One", column: "One", type: .text)])
        XCTAssertEqual(written, ["EA Warnings"])
    }

    // MARK: - generate

    func testSheetsOnlyCanSelectAnEATab() async throws {
        try results([("Mac-1", "FV", "Encrypted")])
        let config = try ConfigLoader.loadFromString("""
        custom_eas:
          - {name: FileVault, column: FV, type: boolean}
        sheets:
          only: [filevault]
        """)
        let tabs = try await generate(config)
        XCTAssertEqual(tabs, ["FileVault"])
    }

    private func generate(_ config: ReportConfig) async throws -> [String] {
        let out = dataDir.appendingPathComponent("out-\(UUID().uuidString)/report.xlsx")
        try await ReportEngine(config: config, dataDir: dataDir)
            .generate(outputURL: out, locateJamfCLI: { nil })
        return try SheetsSettingsTests.tabs(of: out)
    }
}
