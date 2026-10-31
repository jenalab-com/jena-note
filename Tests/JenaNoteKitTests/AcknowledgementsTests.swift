import AppKit
import XCTest
@testable import JenaNoteKit

final class AcknowledgementsTests: XCTestCase {
    func testBundledNoticesAreFoundAndShownInFull() throws {
        let root = try XCTUnwrap(AcknowledgementsWindowController.noticesURL())
        let text = AcknowledgementsWindowController.buildNotices(from: root).string
        // Every bundled notice file appears, with its full text.
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasSuffix("/") }
        for path in files where !(try root.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false) {
            let url = root.appendingPathComponent(path)
            XCTAssertTrue(text.contains(url.lastPathComponent), path)
            let body = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(text.contains(body), path)
        }
        XCTAssertTrue(text.contains("Apache License"))
        // README summary comes before the license texts of the same component.
        let readme = try XCTUnwrap(text.range(of: "README.txt")), license = try XCTUnwrap(text.range(of: "\nLICENSE\n"))
        XCTAssertLessThan(readme.lowerBound, license.lowerBound)
    }

    func testMissingNoticesFolderStillShowsHeading() {
        let text = AcknowledgementsWindowController.buildNotices(from: nil).string
        XCTAssertTrue(text.hasPrefix(L10n.tr("about.licenses")))
    }
}

final class AboutPanelLicenseLinkTests: XCTestCase {
    @MainActor
    func testAboutPanelLinkIsInterceptedToOpenNotices() throws {
        let notices = try XCTUnwrap(AcknowledgementsWindowController.noticesURL())
        let delegate = AppDelegate()
        _ = NSApplication.shared
        delegate.showAbout(nil)
        defer { NSApp.windows.filter { $0.isVisible && $0 is NSPanel }.forEach { $0.close() } }
        let views = AppDelegate.creditsTextViews(linkingTo: notices)
        XCTAssertFalse(views.isEmpty, "credits text view with the license link")
        XCTAssertTrue(views.allSatisfy { $0.delegate === delegate })
        // The click handler claims only the notices link; other links keep default handling.
        let view = try XCTUnwrap(views.first)
        XCTAssertTrue(delegate.textView(view, clickedOnLink: notices, at: 0))
        XCTAssertFalse(delegate.textView(view, clickedOnLink: URL(string: "https://www.jenalab.com")!, at: 0))
        AcknowledgementsWindowController.shared.close()
    }
}
