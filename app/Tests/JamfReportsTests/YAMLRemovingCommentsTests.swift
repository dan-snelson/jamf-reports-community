import XCTest
@testable import JamfReports

/// `YAMLCodec.removingComments(from:)` strips the comments of the diagnostic bundle's copy of
/// config.yaml. A quote opens only at the start of a scalar, so an apostrophe inside a plain
/// value does not hide the comment after it.
final class YAMLRemovingCommentsTests: XCTestCase {

    private func strip(_ line: String) -> String { YAMLCodec.removingComments(from: line) }

    func testAnApostropheInAPlainValueDoesNotHideTheComment() {
        XCTAssertEqual(strip("description: Don't stop # ticket INC-4411"), "description: Don't stop")
        XCTAssertEqual(strip("  - name: O'Brien's Mac # owner"), "  - name: O'Brien's Mac")
        XCTAssertEqual(strip("don't: x # note"), "don't: x")
    }

    func testARealSingleQuotedValueKeepsItsHash() {
        XCTAssertEqual(strip("accent: '#2D5EA2'   # blue"), "accent: '#2D5EA2'")
        XCTAssertEqual(strip("title: 'Fleet # 1' # note"), "title: 'Fleet # 1'")
        XCTAssertEqual(strip("- 'a # b' # c"), "- 'a # b'")
    }

    func testADoubledApostropheStaysInsideTheQuotedValue() {
        XCTAssertEqual(strip("text: 'It''s # fine' # note"), "text: 'It''s # fine'")
        XCTAssertEqual(strip("text: 'It''s' # note"), "text: 'It''s'")
    }

    func testDoubleQuotedValuesAndEscapes() {
        XCTAssertEqual(strip(#"title: "say \"a # b\"" # note"#), #"title: "say \"a # b\"""#)
        XCTAssertEqual(strip(#"title: "Fleet #1""#), #"title: "Fleet #1""#)
    }

    func testAHashNotAfterASpaceStays() {
        XCTAssertEqual(strip("color: red#1 # note"), "color: red#1")
        XCTAssertEqual(strip("url: http://x/#frag"), "url: http://x/#frag")
    }

    func testFlowCollectionsQuoteAfterTheirIndicators() {
        XCTAssertEqual(strip("list: ['a # b', 'c'] # note"), "list: ['a # b', 'c']")
        XCTAssertEqual(strip("list: [one, 'a # b'] # note"), "list: [one, 'a # b']")
        XCTAssertEqual(strip("map: {k: 'a # b'} # note"), "map: {k: 'a # b'}")
    }

    func testAPlainValueWithACommaIsNotAFlowCollection() {
        XCTAssertEqual(strip("note: a, 'b # c"), "note: a, 'b")
    }

    func testCommentOnlyLinesAreDroppedAndOthersKept() {
        XCTAssertEqual(strip("# top\nkey: value\n  # inner\nother: don't # x\n"),
                       "key: value\nother: don't\n")
    }
}
