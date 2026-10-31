import AppKit
import XCTest
@testable import JenaNoteKit

/// 클라우드 드라이브처럼 파일 읽기가 느릴 때 사이드바에서 여러 파일을 연달아 여는 경우.
final class DocumentSwapTests: XCTestCase {
    private var pending: [(url: URL, complete: (NSDocument?, Bool, Error?) -> Void)] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        pending = []
    }

    private func document(_ name: String, _ text: String) -> MarkdownDocument {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(string: text)
        doc.fileURL = URL(fileURLWithPath: "/tmp/jenanote-swap-\(name).md")
        return doc
    }

    private func makeWindow(showing doc: MarkdownDocument) -> EditorWindowController {
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        controller.window?.isReleasedWhenClosed = false
        controller.documentOpener = { [unowned self] url, completion in pending.append((url, completion)) }
        return controller
    }

    /// `canClose` may call back on a later run loop turn.
    private func waitForRequests(_ count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while pending.count < count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func respond(_ url: URL, with doc: NSDocument?, error: Error? = nil) {
        let index = pending.firstIndex { $0.url == url }!
        pending.remove(at: index).complete(doc, false, error)
    }

    func testLaterClickWinsWhenEarlierFileArrivesLast() throws {
        let start = document("start", "처음"), a = document("a", "A 본문"), b = document("b", "B 본문")
        let controller = makeWindow(showing: start)
        controller.openFileFromSidebar(at: a.fileURL!)
        controller.openFileFromSidebar(at: b.fileURL!)
        waitForRequests(2)
        XCTAssertEqual(pending.count, 2, "both reads in flight")

        respond(b.fileURL!, with: b)          // fast file first
        respond(a.fileURL!, with: a)          // slow cloud file last
        XCTAssertTrue(controller.document === b)
        XCTAssertTrue(b.windowControllers.contains(controller))
        XCTAssertFalse(a.windowControllers.contains(controller), "late file must not grab the window")
        XCTAssertFalse(start.windowControllers.contains(controller))
        controller.window?.close()
    }

    func testStaleResultArrivingFirstIsDropped() throws {
        let start = document("start2", "처음"), a = document("a2", "A"), b = document("b2", "B")
        let controller = makeWindow(showing: start)
        controller.openFileFromSidebar(at: a.fileURL!)
        controller.openFileFromSidebar(at: b.fileURL!)
        waitForRequests(2)

        respond(a.fileURL!, with: a)          // superseded request completes first
        XCTAssertTrue(controller.document === start, "nothing applied until the latest request completes")
        respond(b.fileURL!, with: b)
        XCTAssertTrue(controller.document === b)
        XCTAssertTrue(a.windowControllers.isEmpty)
        controller.window?.close()
    }

    func testFailedOpenKeepsCurrentDocumentAndReportsIt() throws {
        let start = document("start3", "그대로"), a = document("a3", "A")
        let controller = makeWindow(showing: start)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.openFileFromSidebar(at: a.fileURL!)
        waitForRequests(1)
        respond(a.fileURL!, with: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))
        XCTAssertTrue(controller.document === start)
        let sheet = try XCTUnwrap(controller.window?.attachedSheet, "failure is shown, not swallowed")
        controller.window?.endSheet(sheet)
        controller.window?.close()
    }

    func testUndecodableFileFailsInsteadOfOpeningEmpty() {
        let doc = MarkdownDocument()
        XCTAssertThrowsError(try doc.read(from: Data([0xFF, 0xFE, 0xB0, 0xA1, 0xC0]), ofType: "net.daringfireball.markdown"))
        XCTAssertNoThrow(try doc.read(from: Data(), ofType: "net.daringfireball.markdown"), "a truly empty file still opens")
        XCTAssertNoThrow(try doc.read(from: Data("본문".utf8), ofType: "net.daringfireball.markdown"))
    }
}
