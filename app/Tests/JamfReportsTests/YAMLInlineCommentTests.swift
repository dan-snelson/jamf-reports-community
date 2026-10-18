import XCTest
@testable import JamfReports

/// The reader's inline-comment scan opens a quote only where a scalar starts, and the writer
/// keeps a value holding a Unicode line break on one line.
final class YAMLInlineCommentTests: XCTestCase {

    private func read(_ text: String) throws -> [String: String] {
        let mapping = try XCTUnwrap(try YAMLCodec.decode(text).root.mapping)
        return Dictionary(uniqueKeysWithValues: mapping.entries.compactMap { entry in
            if case .scalar(.string(let value)) = entry.value { return (entry.key, value) }
            return nil
        })
    }

    func testAnApostropheInAPlainScalarStillEndsAtTheComment() throws {
        let values = try read("note: Don't stop # ticket 4411\nowner: O'Brien's Mac # who\n")
        XCTAssertEqual(values["note"], "Don't stop")
        XCTAssertEqual(values["owner"], "O'Brien's Mac")
    }

    func testADoubledApostropheInASingleQuotedScalarWithAComment() throws {
        let values = try read("text: 'It''s # fine' # note\nplain: 'It''s' # note\n")
        XCTAssertEqual(values["text"], "It's # fine")
        XCTAssertEqual(values["plain"], "It's")
    }

    func testUnicodeLineBreaksInAValueStayOnOneLine() throws {
        for scalar in ["\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}"] {
            var document = YAMLCodec.emptyDocument()
            document.root = .mapping(.init(entries: [
                .init(key: "note", value: .scalar(.string("a\(scalar)b"))),
                .init(key: "after", value: .scalar(.string("kept"))),
            ]))
            let text = try YAMLCodec.encode(document, replacingTopLevelKeys: ["note", "after"])
            let decoded = try YAMLCodec.decode(text)
            XCTAssertEqual(decoded.parseNotes, [], "U+\(scalar.unicodeScalars.first!.value)")
            let values = try read(text)
            XCTAssertEqual(values["note"], "a b")
            XCTAssertEqual(values["after"], "kept")
        }
    }
}
