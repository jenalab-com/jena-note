import XCTest
import AppKit
@testable import JenaNoteKit

final class ReadingSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "jn_readingPageMode")
        UserDefaults.standard.removeObject(forKey: "jn_readingFontScale")
        UserDefaults.standard.removeObject(forKey: "jn_readingLineLength")
    }

    func testDefaults() {
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .scroll)
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(SettingsManager.shared.readingLineLength, 35)
    }

    func testPageModePersists() {
        SettingsManager.shared.readingPageMode = .paged
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "jn_readingPageMode"), "paged")
    }

    func testFontScaleClamps() {
        SettingsManager.shared.readingFontScale = 5.0
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 2.0, accuracy: 0.001)
        SettingsManager.shared.readingFontScale = 0.1
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 0.8, accuracy: 0.001)
    }
}
