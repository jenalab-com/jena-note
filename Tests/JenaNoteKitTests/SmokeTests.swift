import XCTest
@testable import JenaNoteKit

final class SmokeTests: XCTestCase {
    func testKitModuleLinks() {
        // 모듈이 링크되고 테스트 하니스가 동작하는지만 확인
        XCTAssertEqual(SettingsManager.shared.language.rawValue.isEmpty, false)
    }
}
