import XCTest
@testable import Crossdeck

final class EntitlementCacheTests: XCTestCase {

    private func makeEntitlement(_ key: String, validUntil: Int64? = nil) -> PublicEntitlement {
        return PublicEntitlement(
            key: key,
            isActive: true,
            validUntil: validUntil,
            source: PublicEntitlement.EntitlementSource(
                rail: .apple,
                productId: "com.example.\(key)",
                subscriptionId: "sub_test_\(key)"
            ),
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func test_emptyCache_returnsFalseOrNil() {
        let cache = EntitlementCache(storage: MemoryStorage())
        XCTAssertFalse(cache.isEntitledSync("pro", for: "u_1"))
        XCTAssertNil(cache.entitlementsSync(for: "u_1"))
    }

    func test_writeThenRead_roundTrip() async {
        let cache = EntitlementCache(storage: MemoryStorage())
        let snap = EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [makeEntitlement("pro"), makeEntitlement("team")]
        )
        await cache.write(snap)
        XCTAssertTrue(cache.isEntitledSync("pro", for: "u_1"))
        XCTAssertTrue(cache.isEntitledSync("team", for: "u_1"))
        XCTAssertFalse(cache.isEntitledSync("enterprise", for: "u_1"))
    }

    func test_doesNotLeakAcrossUsers() async {
        let cache = EntitlementCache(storage: MemoryStorage())
        await cache.write(EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [makeEntitlement("pro")]
        ))
        XCTAssertFalse(cache.isEntitledSync("pro", for: "u_2"))
        XCTAssertNil(cache.entitlementsSync(for: "u_2"))
    }

    func test_clear_removesSnapshot() async {
        let cache = EntitlementCache(storage: MemoryStorage())
        await cache.write(EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [makeEntitlement("pro")]
        ))
        await cache.clear()
        XCTAssertFalse(cache.isEntitledSync("pro", for: "u_1"))
        XCTAssertNil(cache.entitlementsSync(for: "u_1"))
    }

    func test_persistsAcrossInstances() async {
        let storage = MemoryStorage()
        let first = EntitlementCache(storage: storage)
        await first.write(EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [makeEntitlement("pro")]
        ))
        let second = EntitlementCache(storage: storage)
        XCTAssertTrue(second.isEntitledSync("pro", for: "u_1"))
    }

    func test_validUntilExpired_filteredOut() async {
        let cache = EntitlementCache(storage: MemoryStorage())
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let expired = makeEntitlement("pro", validUntil: nowMs - 1_000)
        await cache.write(EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [expired]
        ))
        XCTAssertFalse(cache.isEntitledSync("pro", for: "u_1"))
        XCTAssertEqual(cache.entitlementsSync(for: "u_1")?.count, 0)
    }

    func test_markRefreshFailed_keepsExistingEntitlementsLive() async {
        // Bank-grade contract: a Crossdeck outage must not fail a
        // paying customer down to free. Last-known-good wins.
        let cache = EntitlementCache(storage: MemoryStorage())
        await cache.write(EntitlementSnapshot(
            developerUserId: "u_1",
            entitlements: [makeEntitlement("pro")]
        ))
        await cache.markRefreshFailed()
        XCTAssertTrue(cache.isEntitledSync("pro", for: "u_1"))
        let freshness = cache.freshness()
        XCTAssertNotNil(freshness?.lastRefreshFailedAt)
    }
}
