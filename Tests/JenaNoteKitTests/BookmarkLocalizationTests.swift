import XCTest
@testable import JenaNoteKit

/// 책갈피 UI 문자열이 지원 언어 전부에 실제로 들어 있는지 확인한다.
/// 키가 빠지면 `L10n.tr` 은 en 폴백을 거쳐 최종적으로 키 문자열 자체를 돌려주므로,
/// "번역 결과 == 키" 인지 보면 누락을 잡을 수 있다.
final class BookmarkLocalizationTests: XCTestCase {

    private let keys = [
        "menu.view.toggleBookmark",
        "menu.view.bookmarkList",
        "reader.bookmark.toggle",
        "reader.bookmark.list",
        "reader.bookmark.empty",
        "reader.bookmark.untitled"
    ]

    private var originalLanguage: SettingsManager.Language!

    override func setUp() {
        super.setUp()
        originalLanguage = SettingsManager.shared.language
    }

    override func tearDown() {
        SettingsManager.shared.language = originalLanguage
        super.tearDown()
    }

    func testAllBookmarkKeysTranslatedInEveryLanguage() {
        for language in SettingsManager.Language.allCases {
            SettingsManager.shared.language = language
            for key in keys {
                let translated = L10n.tr(key)
                XCTAssertNotEqual(translated, key,
                                  "\(language.rawValue) 에 '\(key)' 번역이 없습니다")
                XCTAssertFalse(translated.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language.rawValue) 의 '\(key)' 가 비어 있습니다")
            }
        }
    }
}
