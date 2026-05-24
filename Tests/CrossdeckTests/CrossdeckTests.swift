// Placeholder test target. Concrete tests live below in topic-
// scoped files (ConsentTests.swift, EventValidationTests.swift,
// RetryPolicyTests.swift, etc.) so a failure points directly at
// the module it belongs to.

import XCTest
@testable import Crossdeck

final class CrossdeckSmokeTests: XCTestCase {
    func test_sdkConstants_arePopulated() {
        XCTAssertFalse(SDK.name.isEmpty)
        XCTAssertFalse(SDK.version.isEmpty)
        XCTAssertEqual(SDK.name, "@cross-deck/swift")
    }
}
