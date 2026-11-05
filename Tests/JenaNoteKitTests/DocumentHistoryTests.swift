import Foundation
import AppKit
import CryptoKit
import XCTest
@testable import JenaNoteKit

final class DocumentHistoryTests: XCTestCase {
    func testComparisonViewLaysOutBothColumnsAndHighlightsChanges() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DocumentHistoryComparisonView()
        window.contentView = view
        let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "그는 문을 열었다.\n방은 어두웠다.\n낡은 의자가 있었다.\n그는 돌아섰다.", current: "그는 문을 열었다.\n방 안에는 아침 햇빛이 들었다.\n창가에서 고양이가 울었다.\n새로운 발자국이 보였다.\n그는 돌아섰다."))
        view.show(rows: rows, version: "1차 완성 · 2026. 10. 29.")
        view.layoutSubtreeIfNeeded()
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        let scrolls = descendants(view).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrolls.count, 2)
        for scroll in scrolls {
            XCTAssertGreaterThan(scroll.frame.width, 300)
            XCTAssertGreaterThan(scroll.frame.height, 200)
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertTrue(text.string.contains("~"))
            var highlights = 0
            text.textStorage?.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.string.utf16.count)) { value, _, _ in
                if value != nil { highlights += 1 }
            }
            XCTAssertGreaterThan(highlights, 0)
        }
        if let path = ProcessInfo.processInfo.environment["JENA_DIFF_SCREENSHOT"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testChangeMapShowsWholeDocumentAndSelectsNearestChange() throws {
        _ = NSApplication.shared
        let rows = (0..<100).map { index in
            DocumentHistoryDiff.Row(previousLine: index + 1, currentLine: index + 1,
                                    previous: "before", current: "after",
                                    kind: index == 10 ? .modified : index == 80 ? .added : .unchanged)
        }
        let map = DocumentHistoryChangeMap(frame: NSRect(x: 0, y: 0, width: 20, height: 400))
        map.setRows(rows)
        XCTAssertEqual(map.markers.map(\.row), [10, 80])
        XCTAssertEqual(map.markerRect(at: 0).midY, 42, accuracy: 1)
        XCTAssertEqual(map.markerRect(at: 1).midY, 322, accuracy: 1)
        var selection: Int?
        map.onSelect = { selection = $0 }
        map.selectNearest(to: 320)
        XCTAssertEqual(selection, 1)
        map.selectNearest(to: 0)
        XCTAssertEqual(selection, 0)
        map.setRows([])
        selection = nil
        map.selectNearest(to: 100)
        XCTAssertNil(selection)
    }

    func testComparisonDirectionAndBounds() {
        XCTAssertEqual(DocumentHistoryDiff.compare(previous: "same\nold", current: "same\nnew"), "  same\n− old\n+ new")
        XCTAssertEqual(DocumentHistoryDiff.compare(previous: "", current: "text"), "− \n+ text")
        XCTAssertNil(DocumentHistoryDiff.compare(previous: String(repeating: "x\n", count: 1100), current: String(repeating: "y\n", count: 1100)))
    }
}
