import XCTest
@testable import JenaNoteKit

final class AIClientTimeoutTests: XCTestCase {
    func testTimeoutConstants() {
        XCTAssertEqual(AIClient.defaultTimeout, 120)
        XCTAssertEqual(AIClient.summaryTimeout, 240)
    }

    func testArgumentsUnchangedByTimeout() {
        let policy = URL(fileURLWithPath: "/tmp/p.toml")
        for provider in AIProvider.allCases {
            XCTAssertEqual(AIClient.arguments(for: provider, policy: policy),
                           AIClient.arguments(for: provider, policy: policy, model: nil))
        }
    }
}
