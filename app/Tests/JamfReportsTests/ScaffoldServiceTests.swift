import Foundation
import XCTest
@testable import JamfReports

/// Unit tests for ScaffoldService: the minimal config it writes, the one-time CSV import
/// (`writeConfig(eas:)`), YAML escaping of CSV-supplied text, header parsing and file permissions.
final class ScaffoldServiceTests: XCTestCase {

    // MARK: - Helpers

    private func tempURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-\(name)-\(UUID().uuidString).yaml")
    }

    private func csvURL(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-\(UUID().uuidString).csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func ea(_ column: String, type: String = "text", sample: String = "") -> ProposedEA {
        ProposedEA(name: column, column: column, type: type, sampleValue: sample)
    }

    // MARK: - Minimal config

    func test_writeMinimalConfig_hasNoColumnMappingAndLoads() throws {
        let dest = tempURL(name: "minimal")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeMinimalConfig(to: dest, profile: "my-profile")
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(written.contains("profile: \"my-profile\""))
        XCTAssertFalse(written.contains("columns"), "no column mapping is written")
        XCTAssertFalse(written.contains("allow_live_overview"), "a key nothing reads")
        XCTAssertNoThrow(try ConfigLoader.load(from: dest))
    }

    func test_writeMinimalConfig_setsOwnerOnlyPermissions() throws {
        let dest = tempURL(name: "perms")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeMinimalConfig(to: dest, profile: "test")
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(perms, 0o600, "config.yaml must be written with 0600 permissions")
    }

    // MARK: - One-time EA import

    func test_writeConfig_writesTheProposedEAsAsCustomEAs() throws {
        let dest = tempURL(name: "eas")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(
            to: dest,
            eas: [ea("Boot Drive Percentage Full", type: "percentage"),
                  ea("Agent Running", type: "boolean", sample: "Yes")],
            profile: "p")
        let eas = try XCTUnwrap(ConfigLoader.load(from: dest).customEas)
        XCTAssertEqual(eas.map(\.column), ["Boot Drive Percentage Full", "Agent Running"])
        XCTAssertEqual(eas.map(\.type.rawValue), ["percentage", "boolean"])
        XCTAssertEqual(eas.last?.trueValue, "Yes")
    }

    // MARK: - YAML injection: CSV-supplied text is escaped

    func test_writeConfig_escapesBackslashAndQuoteInAColumnName() throws {
        let dest = tempURL(name: "escape")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(
            to: dest, eas: [ea("Path\\Column"), ea("Name \"Pro\" Column")], profile: "test")
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertFalse(written.contains("\"Path\\Column\""), "unescaped backslash")
        XCTAssertTrue(written.contains("\\\""), "an embedded quote must be escaped")
    }

    /// `CharacterSet.newlines` includes U+2028, and `YAMLCodec` splits the document on it before
    /// it unescapes a quoted scalar. An unescaped one in a column name would let a crafted CSV
    /// header inject a top-level key. All five members of the set must be neutralized.
    func test_writeConfig_lineSeparatorCharacters_cannotInjectTopLevelKey() throws {
        let separators: [(name: String, char: String)] = [
            ("U+2028 LINE SEPARATOR", "\u{2028}"),
            ("U+2029 PARAGRAPH SEPARATOR", "\u{2029}"),
            ("U+0085 NEXT LINE", "\u{0085}"),
            ("U+000B VERTICAL TAB", "\u{000B}"),
            ("U+000C FORM FEED", "\u{000C}"),
        ]
        for (name, separator) in separators {
            let header = "Computer Name\(separator)output:\(separator)  output_dir: pwned"
            let dest = tempURL(name: "line-separator-injection")
            defer { try? FileManager.default.removeItem(at: dest) }
            try ScaffoldService.writeConfig(to: dest, eas: [ea(header)], profile: "test")
            let written = try String(contentsOf: dest, encoding: .utf8)

            let document = try YAMLCodec.decode(written)
            guard case .mapping(let root) = document.root else {
                XCTFail("top-level document must decode as a mapping")
                continue
            }
            let outputEntries = root.entries.filter { $0.key == "output" }
            XCTAssertEqual(outputEntries.count, 1,
                           "\(name) must not inject a duplicate top-level 'output' key")
            XCTAssertEqual(
                outputEntries.first?.value.mapping?.value(for: "output_dir")?.stringValue,
                "Generated Reports", "\(name): the real output_dir must not be shadowed")
        }
    }

    // MARK: - Header parsing

    func test_readSample_stripsBOMAndReadsQuotedFieldsWithCommas() throws {
        let url = try csvURL(content: "\u{FEFF}Computer Name,\"Name, with comma\"\nMac-1,x\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let sample = try ScaffoldService.readSample(from: url)
        XCTAssertEqual(sample.headers, ["Computer Name", "Name, with comma"])
        XCTAssertEqual(sample.rows, [["Mac-1", "x"]])
    }

    func test_readSample_emptyFile_hasNoHeaders() throws {
        let url = try csvURL(content: "")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try ScaffoldService.readSample(from: url).headers.isEmpty)
    }

    // MARK: - Config Doctor's per-field scorer

    /// The per-field scorer (Config Doctor) has no exclusivity, so `model` carries an exclude of
    /// its own for the identifier header.
    func test_bestColumnMatch_modelIgnoresTheIdentifierHeader() {
        let headers = ["Computer Name", "Model Identifier"]
        XCTAssertNil(ScaffoldService.bestColumnMatch(
            headers: headers, logical: "model", family: .computers))
        XCTAssertEqual(
            ScaffoldService.bestColumnMatch(
                headers: headers, logical: "model_identifier", family: .computers)?.header,
            "Model Identifier")
        XCTAssertEqual(
            ScaffoldService.bestColumnMatch(
                headers: headers + ["Model"], logical: "model", family: .computers)?.header,
            "Model")
    }
}
