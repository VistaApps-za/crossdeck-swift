import XCTest
@testable import Crossdeck

final class ConsentTests: XCTestCase {
    func test_scrubEmail_replacesWithToken() {
        let scrubbed = scrubPII("contact me at jane@example.com please")
        XCTAssertEqual(scrubbed, "contact me at <email> please")
    }

    func test_scrubCard_replacesWithToken() {
        let scrubbed = scrubPII("card 4242 4242 4242 4242 expires soon")
        XCTAssertTrue(scrubbed.contains("<card>"), "got \(scrubbed)")
        XCTAssertFalse(scrubbed.contains("4242"))
    }

    func test_scrubDeep_walksNestedDictionaries() {
        let input: [String: Any] = [
            "user": [
                "contact": [
                    "email": "jane@example.com",
                    "card": "4111 1111 1111 1111",
                ],
                "name": "Jane",
            ],
            "ip": "10.0.0.1",
        ]
        let scrubbed = scrubPIIDeep(input) as! [String: Any]
        let user = scrubbed["user"] as! [String: Any]
        let contact = user["contact"] as! [String: Any]
        XCTAssertEqual(contact["email"] as? String, "<email>")
        XCTAssertEqual(contact["card"] as? String, "<card>")
        XCTAssertEqual(user["name"] as? String, "Jane")
    }

    func test_scrubDeep_walksArrays() {
        let input: [String: Any] = [
            "emails": ["a@b.com", "c@d.com"],
        ]
        let scrubbed = scrubPIIDeep(input) as! [String: Any]
        let emails = scrubbed["emails"] as! [String]
        XCTAssertEqual(emails, ["<email>", "<email>"])
    }

    func test_scrubDeep_respectsMaxDepth() {
        // Build a 100-deep nested dictionary.
        var deepest: [String: Any] = ["leaf": "jane@example.com"]
        for _ in 0..<200 { deepest = ["nest": deepest] }
        let scrubbed = scrubPIIDeep(deepest, maxDepth: 10)
        // Just assert it didn't recurse infinitely / crash.
        XCTAssertNotNil(scrubbed)
    }

    func test_consentManager_defaultsToDeny() async {
        let m = ConsentManager()
        let state = await m.state
        XCTAssertFalse(state.analytics)
        XCTAssertFalse(state.errors)
    }

    func test_consentManager_updateAppliesState() async {
        let m = ConsentManager()
        await m.update(ConsentState(analytics: true, errors: false))
        let state = await m.state
        XCTAssertTrue(state.analytics)
        XCTAssertFalse(state.errors)
    }
}
