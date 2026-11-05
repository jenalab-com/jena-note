import XCTest
@testable import JenaNoteCore

final class LocalizationCoreTests: XCTestCase {
    private var original: AppLanguage!

    override func setUp() { original = AppLanguage.current }
    override func tearDown() { AppLanguage.current = original }

    func testLanguageSelectsTableAndPersists() {
        AppLanguage.current = .en
        XCTAssertEqual(AppLanguage.current, .en)
        let english = L10n.tr("dictionary.selectAll")
        AppLanguage.current = .ko
        XCTAssertEqual(L10n.tr("dictionary.selectAll"), "전체 선택")
        XCTAssertNotEqual(english, "전체 선택")
    }

    func testUnknownKeyFallsBackToKey() {
        XCTAssertEqual(L10n.tr("no.such.key"), "no.such.key")
    }
}
