import XCTest
@testable import Crossdeck

/// Phase 3 — the access gate. These cover EntitlementResolution.resolve, the
/// pure decision pillar #2 rides on: a paying subscriber never sees "not Pro"
/// before the device receipt is read, and a verified receipt is honoured
/// offline without waiting for attribution.
final class EntitlementResolutionTests: XCTestCase {
    private func resolve(
        key: String = "pro",
        backend: Bool = false,
        local: Set<String>? = [],
        map: [String: Set<String>] = [:]
    ) -> EntitlementStatus {
        EntitlementResolution.resolve(
            key: key,
            backendGrantsKey: backend,
            localActiveProductIds: local,
            productMap: map
        )
    }

    // 1. Backend grant wins outright — covers cross-device + warm cache. Wins
    //    even while the local read is still pending (nil) and the map is empty.
    func testBackendGrantWins() {
        XCTAssertEqual(resolve(backend: true, local: nil, map: [:]), .entitled)
        XCTAssertEqual(resolve(backend: true, local: ["com.x.pro"], map: [:]), .entitled)
    }

    // 2. Receipt read in flight (local == nil), backend denies → resolving, so
    //    a payer never flashes "not Pro" on cold launch.
    func testLocalPendingResolves() {
        XCTAssertEqual(resolve(backend: false, local: nil, map: [:]), .resolving)
    }

    // 3. Verified receipt mapped to the key → entitled, offline, no backend.
    func testLocalVerifiedMappedGrants() {
        XCTAssertEqual(
            resolve(key: "pro", local: ["com.x.pro"], map: ["com.x.pro": ["pro"]]),
            .entitled
        )
    }

    // 4. Device has a verified active sub the SDK can't name (no map entry) →
    //    resolving ("connect once to restore"), never a hard deny. The sliver.
    func testUnmappedVerifiedSubResolves() {
        XCTAssertEqual(
            resolve(key: "pro", local: ["com.x.unknown"], map: [:]),
            .resolving
        )
        // Even with a partial map that doesn't cover the active product.
        XCTAssertEqual(
            resolve(key: "pro", local: ["com.x.unknown"], map: ["com.x.other": ["other"]]),
            .resolving
        )
    }

    // 5. Free user — local read complete + empty → notEntitled, no flicker.
    func testFreeUserEmptyLocalDenies() {
        XCTAssertEqual(resolve(backend: false, local: [], map: [:]), .notEntitled)
    }

    // 6. Active sub fully mapped, but to a DIFFERENT key than asked → not
    //    entitled for this key (no unmapped sub, so not resolving).
    func testMappedToDifferentKeyDenies() {
        XCTAssertEqual(
            resolve(key: "pro", local: ["com.x.basic"], map: ["com.x.basic": ["basic"]]),
            .notEntitled
        )
    }

    // 7. Mixed: one product backs the key, another is unmapped → the grant
    //    short-circuits before the unmapped check, so .entitled wins.
    func testGrantBeatsUnmappedSibling() {
        XCTAssertEqual(
            resolve(
                key: "pro",
                local: ["com.x.pro", "com.x.mystery"],
                map: ["com.x.pro": ["pro"]]
            ),
            .entitled
        )
    }

    // 8. One product mapping to multiple keys is honoured for each.
    func testProductMappingMultipleKeys() {
        let map = ["com.x.bundle": Set(["pro", "team"])]
        XCTAssertEqual(resolve(key: "pro", local: ["com.x.bundle"], map: map), .entitled)
        XCTAssertEqual(resolve(key: "team", local: ["com.x.bundle"], map: map), .entitled)
        XCTAssertEqual(resolve(key: "admin", local: ["com.x.bundle"], map: map), .notEntitled)
    }
}
