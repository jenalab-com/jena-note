import XCTest
@testable import JenaNoteKit

final class ReadingAnchorTests: XCTestCase {

    // 스니펫 길이(32)보다 충분히 긴 본문
    private let body = """
        첫 번째 문단입니다. 여기서부터 이야기가 시작됩니다.
        두 번째 문단입니다. 읽던 자리를 여기에 표시해 둡니다.
        세 번째 문단입니다. 이야기가 이어집니다.
        네 번째 문단입니다. 여기서 마무리합니다.
        """

    private func offsetOfSecondParagraph() -> Int {
        (body as NSString).range(of: "두 번째 문단").location
    }

    // MARK: - make

    func testMakeCapturesSnippetAtOffset() {
        let offset = offsetOfSecondParagraph()
        let anchor = ReadingAnchor.make(offset: offset, in: body)
        XCTAssertEqual(anchor.characterOffset, offset)
        XCTAssertEqual(anchor.contentLength, (body as NSString).length)
        XCTAssertTrue(anchor.contextSnippet.hasPrefix("두 번째 문단"))
        XCTAssertEqual((anchor.contextSnippet as NSString).length, ReadingAnchor.snippetLength)
    }

    func testMakeClampsOffsetBeyondEnd() {
        let anchor = ReadingAnchor.make(offset: 99_999, in: body)
        XCTAssertEqual(anchor.characterOffset, (body as NSString).length)
        XCTAssertTrue(anchor.contextSnippet.isEmpty)
    }

    func testMakeClampsNegativeOffset() {
        let anchor = ReadingAnchor.make(offset: -5, in: body)
        XCTAssertEqual(anchor.characterOffset, 0)
    }

    func testMakeTruncatesSnippetNearEnd() {
        let ns = body as NSString
        let anchor = ReadingAnchor.make(offset: ns.length - 5, in: body)
        XCTAssertEqual((anchor.contextSnippet as NSString).length, 5)
    }

    // MARK: - resolve: 문서가 그대로일 때

    func testResolveReturnsSameOffsetWhenUnchanged() {
        let offset = offsetOfSecondParagraph()
        let anchor = ReadingAnchor.make(offset: offset, in: body)
        XCTAssertEqual(anchor.resolve(in: body), offset)
    }

    func testResolveHandlesEmptyDocument() {
        let anchor = ReadingAnchor.make(offset: 10, in: body)
        XCTAssertEqual(anchor.resolve(in: ""), 0)
    }

    // MARK: - resolve: 편집으로 오프셋이 밀렸을 때

    func testResolveFollowsInsertionBefore() {
        let offset = offsetOfSecondParagraph()
        let anchor = ReadingAnchor.make(offset: offset, in: body)

        let inserted = "새로 추가된 머리말 문단이 앞에 붙었습니다.\n" + body
        let expected = (inserted as NSString).range(of: "두 번째 문단").location
        XCTAssertNotEqual(expected, offset)             // 실제로 밀렸는지 확인
        XCTAssertEqual(anchor.resolve(in: inserted), expected)
    }

    func testResolveFollowsDeletionBefore() {
        let offset = offsetOfSecondParagraph()
        let anchor = ReadingAnchor.make(offset: offset, in: body)

        let ns = body as NSString
        let firstLine = ns.range(of: "첫 번째 문단입니다. 여기서부터 이야기가 시작됩니다.\n")
        let deleted = ns.replacingCharacters(in: firstLine, with: "")
        let expected = (deleted as NSString).range(of: "두 번째 문단").location
        XCTAssertEqual(anchor.resolve(in: deleted), expected)
    }

    func testResolveFindsSnippetBeyondSearchRadius() {
        let offset = offsetOfSecondParagraph()
        let anchor = ReadingAnchor.make(offset: offset, in: body)

        // 탐색 반경(2048)을 훌쩍 넘는 분량이 앞에 붙어도 전체 재탐색으로 찾아낸다
        let padding = String(repeating: "머리말 단락이 아주 길게 붙었습니다. ", count: 200)
        let inserted = padding + body
        let expected = (inserted as NSString).range(of: "두 번째 문단").location
        XCTAssertGreaterThan(expected - offset, ReadingAnchor.searchRadius)
        XCTAssertEqual(anchor.resolve(in: inserted), expected)
    }

    // MARK: - resolve: 되찾지 못할 때

    func testResolveClampsWhenSnippetGone() {
        let anchor = ReadingAnchor.make(offset: offsetOfSecondParagraph(), in: body)
        let replaced = "전혀 다른 내용으로 통째로 갈아치운 짧은 글."
        let resolved = anchor.resolve(in: replaced)
        XCTAssertGreaterThanOrEqual(resolved, 0)
        XCTAssertLessThanOrEqual(resolved, (replaced as NSString).length)
    }

    func testResolveClampsWhenDocumentShrank() {
        let ns = body as NSString
        let anchor = ReadingAnchor.make(offset: ns.length - 10, in: body)
        let shortened = "짧아진 글."
        XCTAssertLessThanOrEqual(anchor.resolve(in: shortened), (shortened as NSString).length)
    }

    func testResolveWithEmptySnippetClampsToLength() {
        // 문서 맨 끝에서 찍힌 앵커는 스니펫이 없다 — 재탐색 단서가 없으므로 클램프만.
        let anchor = ReadingAnchor.make(offset: (body as NSString).length, in: body)
        XCTAssertTrue(anchor.contextSnippet.isEmpty)
        let shortened = "짧은 글."
        XCTAssertEqual(anchor.resolve(in: shortened), (shortened as NSString).length)
    }

    // MARK: - resolve: 중복 매치

    func testResolvePicksNearestAmongDuplicates() {
        let unit = "같은 문장이 반복됩니다. 여기가 그 자리입니다. 뒤에도 이어집니다.\n"
        let repeated = String(repeating: unit, count: 10)
        let unitLength = (unit as NSString).length

        // 다섯 번째 반복 지점을 앵커로 삼는다
        let target = unitLength * 4
        let anchor = ReadingAnchor.make(offset: target, in: repeated)

        // 같은 문서에서는 제자리를 그대로 찾아야 한다 (첫 매치로 튀지 않음)
        XCTAssertEqual(anchor.resolve(in: repeated), target)

        // 앞에 무언가 끼어들어 제자리가 깨지면, 여러 매치 중 원래 오프셋에 가장
        // 가까운 것을 고른다 — 첫 매치(문서 앞쪽)로 튀지 않는다.
        let prefix = "머리말입니다.\n"
        let prefixLength = (prefix as NSString).length
        XCTAssertNotEqual(prefixLength % unitLength, 0)   // 주기와 어긋나야 제자리가 깨진다
        let shifted = prefix + repeated
        XCTAssertEqual(anchor.resolve(in: shifted), target + prefixLength)
    }

    func testResolveCannotDisambiguatePerfectlyPeriodicText() {
        // 원리적 한계를 명시해 둔다. 삽입량이 반복 주기와 정확히 같으면 앵커 자리에
        // 똑같은 스니펫이 그대로 남으므로 밀렸다는 사실 자체를 알 수 없다.
        // 이때는 "제자리"를 택한다 — 어차피 독자에게는 같은 내용이 보인다.
        let unit = "같은 문장이 반복됩니다. 여기가 그 자리입니다. 뒤에도 이어집니다.\n"
        let repeated = String(repeating: unit, count: 10)
        let target = (unit as NSString).length * 4
        let anchor = ReadingAnchor.make(offset: target, in: repeated)

        XCTAssertEqual(anchor.resolve(in: unit + repeated), target)
    }

    // MARK: - previewText (책갈피 목록 표시용)

    func testPreviewFlattensNewlinesAndSpaces() {
        let text = "첫 줄입니다.\n\n   둘째 줄입니다.\t셋째."
        let preview = ReadingAnchor.previewText(at: 0, in: text)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertFalse(preview.contains("\t"))
        XCTAssertEqual(preview, "첫 줄입니다. 둘째 줄입니다. 셋째.")
    }

    func testPreviewTruncatesWithEllipsis() {
        let text = String(repeating: "가", count: 200)
        let preview = ReadingAnchor.previewText(at: 0, in: text, maxLength: 10)
        XCTAssertEqual(preview, String(repeating: "가", count: 10) + "…")
    }

    func testPreviewStartsAtGivenOffset() {
        let offset = offsetOfSecondParagraph()
        let preview = ReadingAnchor.previewText(at: offset, in: body)
        XCTAssertTrue(preview.hasPrefix("두 번째 문단"))
    }

    func testPreviewOfEmptyOrEndPositionIsEmpty() {
        XCTAssertEqual(ReadingAnchor.previewText(at: 0, in: ""), "")
        XCTAssertEqual(ReadingAnchor.previewText(at: (body as NSString).length, in: body), "")
    }

    func testPreviewClampsOutOfRangeOffset() {
        XCTAssertEqual(ReadingAnchor.previewText(at: 99_999, in: body), "")
        XCTAssertTrue(ReadingAnchor.previewText(at: -10, in: body).hasPrefix("첫 번째 문단"))
    }

    // MARK: - Codable

    func testAnchorRoundTripsThroughJSON() throws {
        let anchor = ReadingAnchor.make(offset: offsetOfSecondParagraph(), in: body)
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(ReadingAnchor.self, from: data)
        XCTAssertEqual(decoded.characterOffset, anchor.characterOffset)
        XCTAssertEqual(decoded.contextSnippet, anchor.contextSnippet)
        XCTAssertEqual(decoded.contentLength, anchor.contentLength)
    }
}
