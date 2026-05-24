import XCTest
@testable import Crossdeck

final class EntitlementCacheTests: XCTestCase {
    func test_emptyCache_returnsNil() async {
        let storage = MemoryStorage()
        let cache = EntitlementCache(storage: storage)
        let set = await cache.entitlements(for: "u_1")
        XCTAssertNil(set)
    }

    func test_writeThenRead_roundTrip() async {
        let storage = MemoryStorage()
        let cache = EntitlementCache(storage: storage)
        let snap = EntitlementSnapshot(
            customerId: "u_1",
            entitlements: ["pro", "team"]
        )
        await cache.write(snap)
        let set = await cache.entitlements(for: "u_1")
        XCTAssertEqual(set, ["pro", "team"])
    }

    func test_doesNotLeakAcrossCustomers() async {
        let storage = MemoryStorage()
        let cache = EntitlementCache(storage: storage)
        await cache.write(EntitlementSnapshot(
            customerId: "u_1",
            entitlements: ["pro"]
        ))
        // u_2 was never written — must NOT receive u_1's set.
        let set = await cache.entitlements(for: "u_2")
        XCTAssertNil(set)
    }

    func test_clear_removesSnapshot() async {
        let storage = MemoryStorage()
        let cache = EntitlementCache(storage: storage)
        await cache.write(EntitlementSnapshot(
            customerId: "u_1",
            entitlements: ["pro"]
        ))
        await cache.clear()
        let set = await cache.entitlements(for: "u_1")
        XCTAssertNil(set)
    }

    func test_persistsAcrossInstances() async {
        let storage = MemoryStorage()
        let first = EntitlementCache(storage: storage)
        await first.write(EntitlementSnapshot(
            customerId: "u_1",
            entitlements: ["pro"]
        ))

        let second = EntitlementCache(storage: storage)
        let set = await second.entitlements(for: "u_1")
        XCTAssertEqual(set, ["pro"])
    }

    func test_isEntitled_quickCheck() async {
        let storage = MemoryStorage()
        let cache = EntitlementCache(storage: storage)
        await cache.write(EntitlementSnapshot(
            customerId: "u_1",
            entitlements: ["pro", "team"]
        ))
        let yes = await cache.isEntitled("pro", for: "u_1")
        let no = await cache.isEntitled("enterprise", for: "u_1")
        let wrongCustomer = await cache.isEntitled("pro", for: "u_2")
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
        XCTAssertFalse(wrongCustomer)
    }
}
