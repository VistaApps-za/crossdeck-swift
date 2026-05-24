import XCTest
@testable import Crossdeck

final class HttpTests: XCTestCase {
    func test_extractSelfHostname_lowercases() {
        XCTAssertEqual(
            extractSelfHostname(from: "https://API.Cross-Deck.COM/v1/events"),
            "api.cross-deck.com"
        )
    }

    func test_extractSelfHostname_returnsNilForGarbage() {
        XCTAssertNil(extractSelfHostname(from: ""))
    }

    func test_isSelfRequest_matchesCaseInsensitively() {
        XCTAssertTrue(isSelfRequest(
            urlString: "https://api.cross-deck.com/v1/events",
            selfHostname: "API.CROSS-DECK.COM"
        ))
    }

    func test_isSelfRequest_returnsFalse_forNilSelfHostname() {
        XCTAssertFalse(isSelfRequest(
            urlString: "https://api.cross-deck.com/v1/events",
            selfHostname: nil
        ))
    }

    func test_isSelfRequest_returnsFalse_forDifferentHost() {
        XCTAssertFalse(isSelfRequest(
            urlString: "https://api.example.com/foo",
            selfHostname: "api.cross-deck.com"
        ))
    }
}
