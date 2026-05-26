// Phase 3.2 contract tests — Swift super-property merge precedence.
//
// Pre-v1.4.0 Swift's track() pipeline had the merge order INVERTED
// vs Web/Node/RN — device payload overrode super-properties, so a
// `register("plan", "pro")` super-property got clobbered by the
// auto-attached device info on every event. Cross-SDK funnel
// queries on super-property keys disagreed per platform.
//
// The merge helper is intentionally pure so the precedence is
// CI-pinned regardless of call-site changes.

import XCTest
@testable import Crossdeck

final class EventPropertyMergeTests: XCTestCase {

    // MARK: - Precedence: caller > super > device

    func test_caller_overrides_super() {
        let merged = EventPropertyMerge.merge(
            device: [:],
            superProperties: ["plan": "free"],
            caller: ["plan": "pro"]
        )
        XCTAssertEqual(merged["plan"] as? String, "pro")
    }

    func test_super_overrides_device() {
        // The flagship Phase 3.2 invariant — super-properties MUST
        // win over auto-attached device info. Pre-v1.4.0 device
        // won, silently overriding every developer-registered
        // super-property whose key collided with a device field.
        let merged = EventPropertyMerge.merge(
            device: ["platform": "auto_detected"],
            superProperties: ["platform": "test_platform"],
            caller: [:]
        )
        XCTAssertEqual(merged["platform"] as? String, "test_platform")
    }

    func test_caller_overrides_device() {
        let merged = EventPropertyMerge.merge(
            device: ["platform": "auto_detected"],
            superProperties: [:],
            caller: ["platform": "caller_value"]
        )
        XCTAssertEqual(merged["platform"] as? String, "caller_value")
    }

    func test_full_precedence_chain() {
        // device < super < caller — all three layers populated;
        // caller value MUST win at the bottom of the chain.
        let merged = EventPropertyMerge.merge(
            device: ["plan": "device_default"],
            superProperties: ["plan": "super_value"],
            caller: ["plan": "caller_wins"]
        )
        XCTAssertEqual(merged["plan"] as? String, "caller_wins")
    }

    // MARK: - Non-overlapping keys preserved

    func test_distinct_keys_all_preserved() {
        let merged = EventPropertyMerge.merge(
            device: ["platform": "ios"],
            superProperties: ["plan": "pro"],
            caller: ["action": "tap"]
        )
        XCTAssertEqual(merged["platform"] as? String, "ios")
        XCTAssertEqual(merged["plan"] as? String, "pro")
        XCTAssertEqual(merged["action"] as? String, "tap")
        XCTAssertEqual(merged.count, 3)
    }

    func test_empty_inputs_produce_empty_merge() {
        XCTAssertEqual(
            EventPropertyMerge.merge(device: [:], superProperties: [:], caller: [:]).count,
            0
        )
    }

    // MARK: - Cross-SDK parity contract

    func test_matchesWebNodeRNPrecedence() {
        // Web/Node/RN all use this order. The Swift test is the
        // tripwire: if a future refactor breaks the merge order,
        // CI catches it before native funnels start disagreeing
        // with TS funnels in production.
        let merged = EventPropertyMerge.merge(
            device: ["k": "device", "only_device": "d"],
            superProperties: ["k": "super", "only_super": "s"],
            caller: ["k": "caller", "only_caller": "c"]
        )
        XCTAssertEqual(merged["k"] as? String, "caller", "Caller value MUST win")
        XCTAssertEqual(merged["only_device"] as? String, "d")
        XCTAssertEqual(merged["only_super"] as? String, "s")
        XCTAssertEqual(merged["only_caller"] as? String, "c")
    }
}
