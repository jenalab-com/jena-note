import XCTest
@testable import JenaNoteCore

final class DocumentHistoryDiffTests: XCTestCase {
    func testAlignedComparisonPreservesLineNumbersAndClassifiesChanges() throws {
        let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "start\nold\nend", current: "start\nnew\nextra\nend"))
        XCTAssertEqual(rows.map(\.kind), [.unchanged, .modified, .added, .unchanged])
        XCTAssertEqual(rows.map(\.previousLine), [1, 2, nil, 3])
        XCTAssertEqual(rows.map(\.currentLine), [1, 2, 3, 4])
        XCTAssertEqual(rows[1].previous, "old")
        XCTAssertEqual(rows[1].current, "new")
        XCTAssertNil(rows[2].previous)
        let deleted = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "first\ndeleted\nlast", current: "first\nlast"))
        XCTAssertEqual(deleted[1].kind, .removed)
        XCTAssertNil(deleted[1].currentLine)
        XCTAssertEqual(deleted.last?.currentLine, 2)
    }

    func testComparisonReconstructsBothInputsWithRepeatedAndEmptyLines() throws {
        for (previous, current) in [("a\na\n\nb", "a\n\nb\na"), ("", "new"), ("old", ""), ("same", "same")] {
            let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: previous, current: current))
            XCTAssertEqual(rows.compactMap(\.previous).joined(separator: "\n"), previous)
            XCTAssertEqual(rows.compactMap(\.current).joined(separator: "\n"), current)
        }
    }
}
