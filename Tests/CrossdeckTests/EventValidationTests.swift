import XCTest
@testable import Crossdeck

final class EventValidationTests: XCTestCase {

    private func warningKinds(_ result: ValidationResult) -> [ValidationWarningKind] {
        return result.warnings.map { $0.kind }
    }

    func test_accepts_simpleProperties() {
        let result = validateEventProperties([
            "plan": "pro",
            "trial_days": 14,
            "is_premium": true,
            "amount": 9.99,
        ])
        XCTAssertEqual(result.properties.count, 4)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func test_accepts_nestedDictionary() {
        let result = validateEventProperties([
            "user": ["id": "u_1", "level": 3],
            "tags": ["a", "b", "c"],
        ])
        XCTAssertEqual(result.properties.count, 2)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func test_coerces_NaN_toNull_andEmitsWarning() {
        let result = validateEventProperties(["amount": Double.nan])
        XCTAssertTrue(result.properties["amount"] is NSNull)
        XCTAssertEqual(warningKinds(result), [.notFinite])
    }

    func test_coerces_Infinity_toNull_andEmitsWarning() {
        let result = validateEventProperties(["amount": Double.infinity])
        XCTAssertTrue(result.properties["amount"] is NSNull)
        XCTAssertEqual(warningKinds(result), [.notFinite])
    }

    func test_drops_unencodableClassInstance_andEmitsWarning() {
        class Custom { let x = 1 }
        let result = validateEventProperties(["bad": Custom()])
        XCTAssertNil(result.properties["bad"])
        XCTAssertEqual(warningKinds(result), [.nonSerialisable])
    }

    func test_replaces_cyclicNSMutableDictionary_withMarker_andEmitsWarning() {
        let a = NSMutableDictionary()
        let b = NSMutableDictionary()
        a["b"] = b
        b["a"] = a
        let result = validateEventProperties(["root": a])
        // Cycle is replaced with the "[circular]" marker rather than
        // throwing — track() keeps going.
        XCTAssertTrue(result.warnings.contains { $0.kind == .circularReference })
    }

    func test_replaces_excessiveDepth_withMarker_andEmitsWarning() {
        var nested: Any = "leaf"
        for _ in 0..<(validationMaxDepth + 5) {
            nested = ["x": nested] as [String: Any]
        }
        let result = validateEventProperties(["root": nested])
        XCTAssertTrue(result.warnings.contains { $0.kind == .depthExceeded })
    }

    func test_truncates_oversizeString_andEmitsWarning() {
        let huge = String(repeating: "x", count: maxStringLength * 2)
        let result = validateEventProperties(["msg": huge])
        let truncated = result.properties["msg"] as? String
        XCTAssertNotNil(truncated)
        XCTAssertLessThanOrEqual(truncated?.count ?? 0, maxStringLength)
        XCTAssertTrue(result.warnings.contains { $0.kind == .truncatedString })
    }

    func test_coerces_Date_toIso8601() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = validateEventProperties(["when": date])
        let str = result.properties["when"] as? String
        XCTAssertNotNil(str)
        XCTAssertTrue(str?.contains("2023") == true) // 2023-11-14
    }

    func test_coerces_URL_toString() {
        let url = URL(string: "https://example.com/foo")!
        let result = validateEventProperties(["link": url])
        XCTAssertEqual(result.properties["link"] as? String, "https://example.com/foo")
    }

    func test_coerces_UUID_toString() {
        let uuid = UUID()
        let result = validateEventProperties(["id": uuid])
        XCTAssertEqual(result.properties["id"] as? String, uuid.uuidString)
    }
}
