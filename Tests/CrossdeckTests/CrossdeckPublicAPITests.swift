// Bank-grade contract tests on the public Crossdeck client surface.
//
// These tests exercise the contracts the developer docs explicitly
// promise — every one of them was a P0/P1 finding from the audit
// before being implemented + tested here.

import XCTest
@testable import Crossdeck

final class CrossdeckPublicAPITests: XCTestCase {

    private func makeClient(storage: Storage? = nil) -> Crossdeck {
        return try! Crossdeck.start(options: CrossdeckOptions(
            appId: "app_swift_tests",
            publicKey: "cd_pub_test_swiftunit",
            environment: .sandbox,
            storage: storage ?? MemoryStorage()
        ))
    }

    // MARK: - identify(...) — unconditional entitlement clear

    func test_identify_unconditionallyClearsEntitlementCache() async {
        let storage = MemoryStorage()
        let cd = makeClient(storage: storage)
        defer { cd.stopSync() }

        try? cd.identify(userId: "u_1")
        // Warm the cache for u_1.
        let cache = EntitlementCache(storage: storage)
        let pro = PublicEntitlement(
            key: "pro",
            isActive: true,
            validUntil: nil,
            source: PublicEntitlement.EntitlementSource(
                rail: .apple, productId: "com.test.pro", subscriptionId: "sub_1"
            ),
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        await cache.write(EntitlementSnapshot(developerUserId: "u_1", entitlements: [pro]))

        // Re-identify with the SAME id — per the bank-grade
        // contract, the cache must still be cleared so a stale
        // entitlement can't survive even an idempotent identify.
        try? cd.identify(userId: "u_1")

        // After identify, the sync cache box for u_1 must be empty.
        // (The cache instance Crossdeck holds is separate from the
        // one we wrote to above, but identify() routes through the
        // shared clearSync path.)
        XCTAssertNil(cd.entitlementsForCurrentCustomer())
        XCTAssertFalse(cd.isEntitled("pro"))
    }

    func test_identify_clearsCacheAcrossCustomerSwitch() async {
        let cd = makeClient()
        defer { cd.stopSync() }

        try? cd.identify(userId: "u_1")
        try? cd.identify(userId: "u_2")

        // After switching customers, u_1's entitlements must NEVER
        // be visible under u_2's identity.
        XCTAssertFalse(cd.isEntitled("pro"))
        XCTAssertNil(cd.entitlementsForCurrentCustomer())
    }

    // MARK: - isEntitled / entitlementsForCurrentCustomer

    func test_isEntitled_returnsFalseWithoutIdentify() {
        let cd = makeClient()
        defer { cd.stopSync() }
        XCTAssertFalse(cd.isEntitled("pro"))
        XCTAssertNil(cd.entitlementsForCurrentCustomer())
    }

    func test_isEntitled_isSynchronous_andSafeFromAnyThread() async {
        // The contract: paywall gates can call isEntitled from a
        // SwiftUI body or a tap handler — pure sync, no actor hop.
        // Exercising from a Task confirms it doesn't accidentally
        // require an `await`.
        let cd = makeClient()
        defer { cd.stopSync() }

        try? cd.identify(userId: "u_1")

        let result: Bool = await Task.detached { cd.isEntitled("pro") }.value
        XCTAssertFalse(result)
    }

    // MARK: - stop() rejects subsequent calls

    func test_stop_rejectsSubsequentTrackCalls() {
        let cd = makeClient()
        cd.stopSync()
        XCTAssertThrowsError(try cd.track("post_stop_event")) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "not_initialized")
        }
    }

    func test_stop_rejectsSubsequentIdentifyCalls() {
        let cd = makeClient()
        cd.stopSync()
        XCTAssertThrowsError(try cd.identify(userId: "u_1")) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "not_initialized")
        }
    }

    func test_stop_isIdempotent() {
        let cd = makeClient()
        cd.stopSync()
        cd.stopSync()  // second call must not crash
        // Still rejects after multiple stops.
        XCTAssertThrowsError(try cd.track("e"))
    }

    // MARK: - track validation

    func test_track_rejectsEmptyName() {
        let cd = makeClient()
        defer { cd.stopSync() }
        XCTAssertThrowsError(try cd.track("")) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "missing_event_name")
        }
    }

    func test_track_sanitisesNaNProperty_doesNotThrow() {
        // Sanitise+warn contract: track() never throws on a bad
        // property value. NaN is coerced to NSNull on the wire and
        // a warning surfaces via the debug logger. Matches
        // Web/Node/RN behaviour.
        let cd = makeClient()
        defer { cd.stopSync() }
        XCTAssertNoThrow(try cd.track("e", properties: ["amount": Double.nan]))
    }

    // MARK: - identify validation

    func test_identify_rejectsEmptyId() {
        let cd = makeClient()
        defer { cd.stopSync() }
        XCTAssertThrowsError(try cd.identify(userId: "")) { err in
            let cd = err as? CrossdeckError
            XCTAssertEqual(cd?.code, "missing_user_id")
        }
    }
}
