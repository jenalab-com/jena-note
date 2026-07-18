import XCTest
@testable import JenaNoteKit

final class FileSearcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSearcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func write(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - searchSync

    func testBasicMatchWithLineNumberAndOrdinal() throws {
        try write("a.md", "첫 줄\n둘째 줄에 회의록 있음\n셋째 줄")
        try write("b.md", "관련 없는 내용")

        let (results, truncated) = FileSearcher.searchSync(query: "회의록", folders: [tempDir])

        XCTAssertFalse(truncated)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileURL.lastPathComponent, "a.md")
        XCTAssertEqual(results[0].hits.count, 1)
        let hit = results[0].hits[0]
        XCTAssertEqual(hit.lineNumber, 2)
        XCTAssertEqual(hit.lineText, "둘째 줄에 회의록 있음")
        XCTAssertEqual(hit.ordinalInFile, 0)
        let ns = hit.lineText as NSString
        XCTAssertEqual(ns.substring(with: hit.matchRangeInLine), "회의록")
    }

    func testCaseInsensitiveMatch() throws {
        try write("a.md", "Meeting notes\nmeeting again\nMEETING")
        let (results, _) = FileSearcher.searchSync(query: "meeting", folders: [tempDir])
        XCTAssertEqual(results[0].hits.count, 3)
    }

    func testOrdinalCountsAcrossLinesAndWithinLine() throws {
        try write("a.md", "노트 그리고 노트\n다른 줄\n마지막 노트")
        let (results, _) = FileSearcher.searchSync(query: "노트", folders: [tempDir])
        let hits = results[0].hits
        XCTAssertEqual(hits.map(\.ordinalInFile), [0, 1, 2])
        XCTAssertEqual(hits.map(\.lineNumber), [1, 1, 3])
    }

    func testEmptyOrWhitespaceQueryReturnsNothing() throws {
        try write("a.md", "내용")
        XCTAssertTrue(FileSearcher.searchSync(query: "", folders: [tempDir]).0.isEmpty)
        XCTAssertTrue(FileSearcher.searchSync(query: "   ", folders: [tempDir]).0.isEmpty)
    }

    func testNonMarkdownFilesIgnored() throws {
        try write("a.txt", "회의록")
        try write("sub/b.md", "회의록")
        let (results, _) = FileSearcher.searchSync(query: "회의록", folders: [tempDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileURL.lastPathComponent, "b.md")
    }

    func testLargeFileSkipped() throws {
        let big = String(repeating: "x", count: FileSearcher.maxFileSizeBytes + 1) + " 회의록"
        try write("big.md", big)
        try write("small.md", "회의록")
        let (results, _) = FileSearcher.searchSync(query: "회의록", folders: [tempDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileURL.lastPathComponent, "small.md")
    }

    func testTruncationAtMaxTotalHits() throws {
        let line = "토큰 토큰 토큰 토큰 토큰\n"   // 줄당 5매치
        try write("a.md", String(repeating: line, count: 150))  // 750매치 > 500
        let (results, truncated) = FileSearcher.searchSync(query: "토큰", folders: [tempDir])
        XCTAssertTrue(truncated)
        XCTAssertEqual(results.reduce(0) { $0 + $1.hits.count }, FileSearcher.maxTotalHits)
    }

    // MARK: - makeSnippet

    func testSnippetShortLinePassthrough() {
        let line = "짧은 줄의 회의록 문장"
        let range = (line as NSString).range(of: "회의록")
        let s = FileSearcher.makeSnippet(lineText: line, matchRange: range)
        XCTAssertEqual(s.text, line)
        XCTAssertEqual((s.text as NSString).substring(with: s.highlight), "회의록")
    }

    func testSnippetTrimsLeadingWhitespace() {
        let line = "        들여쓴 회의록"
        let range = (line as NSString).range(of: "회의록")
        let s = FileSearcher.makeSnippet(lineText: line, matchRange: range)
        XCTAssertEqual(s.text, "들여쓴 회의록")
        XCTAssertEqual((s.text as NSString).substring(with: s.highlight), "회의록")
    }

    func testSnippetWindowsLongLineAroundMatch() {
        let prefix = String(repeating: "a", count: 200)
        let line = prefix + "회의록" + String(repeating: "b", count: 200)
        let range = (line as NSString).range(of: "회의록")
        let s = FileSearcher.makeSnippet(lineText: line, matchRange: range, maxLength: 80)
        XCTAssertTrue(s.text.hasPrefix("…"))
        XCTAssertTrue(s.text.hasSuffix("…"))
        XCTAssertLessThanOrEqual((s.text as NSString).length, 82) // maxLength + 앞뒤 …
        XCTAssertEqual((s.text as NSString).substring(with: s.highlight), "회의록")
    }

    // MARK: - SearchMatchLocator

    func testLocatorFindsNthOccurrence() {
        let text = "하나 노트 둘 노트 셋 노트"
        let r = SearchMatchLocator.range(ofOccurrence: 2, query: "노트", in: text)
        XCTAssertNotNil(r)
        XCTAssertEqual((text as NSString).substring(with: r!), "노트")
        // 세 번째(ordinal 2) 매치는 마지막 것
        let last = (text as NSString).range(of: "노트", options: .backwards)
        XCTAssertEqual(r, last)
    }

    func testLocatorCaseInsensitive() {
        let r = SearchMatchLocator.range(ofOccurrence: 0, query: "note", in: "My NOTE here")
        XCTAssertEqual(r, NSRange(location: 3, length: 4))
    }

    func testLocatorReturnsNilWhenMissing() {
        XCTAssertNil(SearchMatchLocator.range(ofOccurrence: 5, query: "노트", in: "노트 하나뿐"))
        XCTAssertNil(SearchMatchLocator.range(ofOccurrence: 0, query: "", in: "아무거나"))
    }
}
