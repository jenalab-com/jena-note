import AppKit
import XCTest
@testable import JenaNoteKit

/// 문서를 여는 동안의 스켈레톤. 큰 파일은 바로, 작은 파일은 늦어질 때만 보인다.
final class DocumentLoadingTests: XCTestCase {
    private var pending: [(NSDocument?, Bool, Error?) -> Void] = []
    private var files: [URL] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        pending = []
    }

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
        super.tearDown()
    }

    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jenanote-loading-\(UUID().uuidString).md")
        try Data(repeating: 0x61, count: bytes).write(to: url)
        files.append(url)
        return url
    }

    private func makeWindow() throws -> (MarkdownDocument, EditorWindowController) {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(string: "처음")
        doc.fileURL = try file(bytes: 10)
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        controller.window?.isReleasedWhenClosed = false
        controller.window?.setContentSize(NSSize(width: 1000, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        controller.documentOpener = { [unowned self] _, completion in pending.append(completion) }
        return (doc, controller)
    }

    private func close(_ doc: MarkdownDocument, _ controller: EditorWindowController) {
        controller.window?.close()
        doc.removeWindowController(controller)
    }

    private func waitForRequest() {
        let deadline = Date().addingTimeInterval(2)
        while pending.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func skeletons(in controller: EditorWindowController) -> [DocumentLoadingView] {
        controller.window?.contentView?.subviews.compactMap { $0 as? DocumentLoadingView } ?? []
    }

    func testLargeFileShowsTheSkeletonBeforeReadingAndRemovesItAfterwards() throws {
        let (doc, controller) = try makeWindow()
        defer { close(doc, controller) }
        let url = try file(bytes: 200_000)
        controller.openFileFromSidebar(at: url)
        waitForRequest()
        XCTAssertEqual(skeletons(in: controller).count, 1, "읽기 전에 이미 보인다")
        let pane = try XCTUnwrap(controller.documentPaneView)
        XCTAssertEqual(skeletons(in: controller).first?.frame.width, pane.bounds.width, "문서 영역만 덮는다")

        let next = MarkdownDocument()
        next.content = NSMutableAttributedString(string: "새 문서")
        next.fileURL = url
        pending.removeFirst()(next, false, nil)
        spin(0.4)

        XCTAssertTrue(skeletons(in: controller).isEmpty)
        next.removeWindowController(controller)
    }

    func testSmallFileThatOpensQuicklyNeverFlashesTheSkeleton() throws {
        let (doc, controller) = try makeWindow()
        defer { close(doc, controller) }
        controller.openFileFromSidebar(at: try file(bytes: 100))
        waitForRequest()
        XCTAssertTrue(skeletons(in: controller).isEmpty)

        pending.removeFirst()(nil, false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        spin(0.3)

        XCTAssertTrue(skeletons(in: controller).isEmpty, "지연 타이머도 취소된다")
    }

    func testSlowSmallFileShowsTheSkeletonAndFailureRemovesIt() throws {
        let (doc, controller) = try makeWindow()
        defer { close(doc, controller) }
        controller.openFileFromSidebar(at: try file(bytes: 100))
        waitForRequest()
        spin(0.3)
        XCTAssertEqual(skeletons(in: controller).count, 1, "클라우드 내려받기처럼 늦어지면 보인다")

        pending.removeFirst()(nil, false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        spin(0.4)

        XCTAssertTrue(skeletons(in: controller).isEmpty, "열기에 실패하면 남아 있으면 안 된다")
    }

    /// 처음 여는 창은 그리는 동안 보이지 않아서, 큰 문서는 창을 먼저 띄워야 한다.
    func testLargeDocumentInANewWindowIsShownBeforeRenderingAndCleansUp() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(string: String(repeating: "바다 건너 등대가 깜빡였다.\n", count: 3_600))
        let controller = EditorWindowController()
        controller.window?.isReleasedWhenClosed = false
        doc.addWindowController(controller)
        defer {
            doc.updateChangeCount(.changeCleared)
            close(doc, controller)
        }
        XCTAssertEqual(controller.window?.isVisible, true)

        spin(0.4)

        XCTAssertTrue(skeletons(in: controller).isEmpty)
    }

    func testSkeletonLeavesTheStatusBarVisible() throws {
        let (doc, controller) = try makeWindow()
        defer { close(doc, controller) }
        controller.openFileFromSidebar(at: try file(bytes: 200_000))
        waitForRequest()
        let skeleton = try XCTUnwrap(skeletons(in: controller).first)
        XCTAssertGreaterThanOrEqual(skeleton.frame.minY, StatusBarView.barHeight)
        pending.removeFirst()(nil, false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        spin(0.3)
    }
}
