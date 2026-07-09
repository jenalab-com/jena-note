import XCTest
@testable import JenaNoteKit

/// 외부(다른 앱·에이전트)가 파일을 고쳐 썼을 때 문서가 조용히 다시 읽히는지 검증.
/// (읽기 모드·글자수 갱신은 .documentDidReloadFromDisk 알림에 매달려 있으므로,
///  리로드 판정과 알림 발행이 이 동작의 핵심이다.)
final class ExternalReloadTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalReloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDocument(initialText: String) throws -> (MarkdownDocument, URL) {
        let url = tempDir.appendingPathComponent("note.md")
        try initialText.data(using: .utf8)!.write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        return (doc, url)
    }

    /// 디스크의 파일을 새 내용으로 바꾸고 수정 시각을 미래로 밀어 외부 변경을 흉내낸다.
    private func rewriteOnDisk(_ url: URL, text: String) throws {
        try text.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
    }

    func testReloadsCleanDocumentWhenFileChangesOnDisk() throws {
        let (doc, url) = try makeDocument(initialText: "원래 내용")
        try rewriteOnDisk(url, text: "바뀐 내용")

        let reloaded = expectation(forNotification: .documentDidReloadFromDisk, object: doc)
        doc.reloadFromDiskIfClean()

        wait(for: [reloaded], timeout: 2)
        // 파서는 마지막 블록 뒤에 개행을 붙이므로 trailing newline 을 무시하고 비교한다.
        XCTAssertEqual(doc.content.string.trimmingCharacters(in: .newlines), "바뀐 내용")
    }

    func testDoesNotClobberUnsavedEdits() throws {
        let (doc, url) = try makeDocument(initialText: "원래 내용")
        doc.textDidChange(NSAttributedString(string: "미저장 편집"))
        try rewriteOnDisk(url, text: "바뀐 내용")

        doc.reloadFromDiskIfClean()

        XCTAssertEqual(doc.content.string, "미저장 편집",
                       "미저장 편집이 있으면 외부 변경으로 덮어쓰지 않아야 한다")
    }

    func testSkipsReloadWhenFileUnchanged() throws {
        let (doc, _) = try makeDocument(initialText: "원래 내용")

        var reloadCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .documentDidReloadFromDisk, object: doc, queue: nil) { _ in
            reloadCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.reloadFromDiskIfClean()

        XCTAssertEqual(reloadCount, 0, "수정 시각이 같으면 다시 읽지 않아야 한다")
        XCTAssertEqual(doc.content.string.trimmingCharacters(in: .newlines), "원래 내용")
    }
}
