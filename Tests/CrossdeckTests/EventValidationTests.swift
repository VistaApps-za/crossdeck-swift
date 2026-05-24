import XCTest
@testable import Crossdeck

final class EventValidationTests: XCTestCase {
    func test_accepts_simpleProperties() throws {
        try validateEventProperties([
            "plan": "pro",
            "trial_days": 14,
            "is_premium": true,
            "amount": 9.99,
        ])
    }

    func test_accepts_nestedDictionary() throws {
        try validateEventProperties([
            "user": ["id": "u_1", "level": 3],
            "tags": ["a", "b", "c"],
        ])
    }

    func test_rejects_NaNDouble() {
        XCTAssertThrowsError(try validateEventProperties(["amount": Double.nan])) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "event_property_not_finite")
        }
    }

    func test_rejects_InfinityDouble() {
        XCTAssertThrowsError(try validateEventProperties(["amount": Double.infinity])) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "event_property_not_finite")
        }
    }

    func test_rejects_unencodableClassInstance() {
        class Custom { let x = 1 }
        XCTAssertThrowsError(try validateEventProperties(["bad": Custom()])) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "event_property_not_encodable")
        }
    }

    func test_rejects_cyclicNSMutableDictionary() {
        let a = NSMutableDictionary()
        let b = NSMutableDictionary()
        a["b"] = b
        b["a"] = a
        XCTAssertThrowsError(try validateEventProperties(["root": a])) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "event_properties_cyclic")
        }
    }

    func test_rejects_excessiveDepth() {
        var nested: Any = "leaf"
        for _ in 0..<(validationMaxDepth + 5) {
            nested = ["x": nested] as [String: Any]
        }
        XCTAssertThrowsError(try validateEventProperties(["root": nested])) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "event_properties_too_deep")
        }
    }
}
