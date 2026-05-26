// Phase 1.3-swift contract tests — bank-grade per-user
// entitlement cache isolation parity with Web/RN/Android.
//
// Same contract registered in
// `contracts/entitlements/per-user-cache-isolation.json` —
// Swift joined the applies_to list in v1.4.x after the founder
// caught the missing entry in the dogfood pass.

import XCTest
@testable import Crossdeck

final class EntitlementCacheIsolationTests: XCTestCase {

    /// Storage spy — exposes the underlying map so assertions can
    /// inspect physical keys.
    private final class InspectableMemoryStorage: Storage, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var map: [String: String] = [:]

        func getString(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return map[key]
        }
        func setString(_ value: String, forKey key: String) {
            lock.lock(); defer { lock.unlock() }
            map[key] = value
        }
        func remove(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            map.removeValue(forKey: key)
        }
        var keys: [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(map.keys)
        }
    }

    private func entitlement(_ key: String) -> PublicEntitlement {
        PublicEntitlement(
            key: key,
            isActive: true,
            validUntil: nil,
            source: PublicEntitlement.EntitlementSource(
                rail: .apple,
                productId: "p_\(key)",
                subscriptionId: "sub_\(key)"
            ),
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    // MARK: - Layer (a): physical key separation

    func test_identifiedWritesLandUnderPerUserSha256Key() async {
        let storage = InspectableMemoryStorage()
        let cache = EntitlementCache(storage: storage)

        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(
            developerUserId: "alice",
            entitlements: [entitlement("pro")]
        ))

        let expectedKey = "crossdeck:entitlements:\(IdempotencyKey.sha256Hex("alice"))"
        XCTAssertTrue(
            storage.keys.contains(expectedKey),
            "Expected per-user key \(expectedKey); got \(storage.keys.joined(separator: ", "))"
        )
    }

    func test_twoUsersUseTwoDifferentStorageKeys() async {
        let storage = InspectableMemoryStorage()
        let cache = EntitlementCache(storage: storage)

        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(developerUserId: "alice", entitlements: [entitlement("pro")]))
        await cache.setUserKey("bob")
        await cache.write(EntitlementSnapshot(developerUserId: "bob", entitlements: [entitlement("trial")]))

        let aliceKey = "crossdeck:entitlements:\(IdempotencyKey.sha256Hex("alice"))"
        let bobKey = "crossdeck:entitlements:\(IdempotencyKey.sha256Hex("bob"))"
        XCTAssertTrue(storage.keys.contains(aliceKey))
        XCTAssertTrue(storage.keys.contains(bobKey))
        XCTAssertNotEqual(aliceKey, bobKey)
    }

    // MARK: - Layer (b): identify() unconditional in-memory wipe

    func test_identifyB_makesAEntitlementsUnreachable() async {
        let storage = InspectableMemoryStorage()
        let cache = EntitlementCache(storage: storage)

        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(developerUserId: "alice", entitlements: [entitlement("pro")]))
        XCTAssertTrue(cache.isEntitledSync("pro", for: "alice"))

        await cache.setUserKey("bob")
        XCTAssertFalse(cache.isEntitledSync("pro", for: "bob"))
        XCTAssertNil(cache.entitlementsSync(for: "bob"))
    }

    func test_identifyBThenA_rehydratesAFromStorage() async {
        let storage = InspectableMemoryStorage()
        let cache = EntitlementCache(storage: storage)

        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(developerUserId: "alice", entitlements: [entitlement("pro")]))
        await cache.setUserKey("bob")
        await cache.write(EntitlementSnapshot(developerUserId: "bob", entitlements: [entitlement("trial")]))

        await cache.setUserKey("alice")
        XCTAssertTrue(cache.isEntitledSync("pro", for: "alice"))
        XCTAssertFalse(cache.isEntitledSync("trial", for: "alice"))
    }

    // MARK: - Layer (c): clearAll() wipes EVERY per-user slot

    func test_clearAll_removesEveryPerUserStorageKeyPlusIndex() async {
        let storage = InspectableMemoryStorage()
        let cache = EntitlementCache(storage: storage)

        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(developerUserId: "alice", entitlements: [entitlement("pro")]))
        await cache.setUserKey("bob")
        await cache.write(EntitlementSnapshot(developerUserId: "bob", entitlements: [entitlement("trial")]))
        await cache.setUserKey("charlie")
        await cache.write(EntitlementSnapshot(developerUserId: "charlie", entitlements: [entitlement("enterprise")]))

        await cache.clearAll()

        let remaining = storage.keys.filter { $0.hasPrefix("crossdeck:entitlements") }
        XCTAssertEqual(remaining, [], "clearAll() must wipe every per-user slot + the index")
    }

    func test_clearAll_doesNotTouchUnrelatedHostAppKeys() async {
        let storage = InspectableMemoryStorage()
        storage.setString("{\"theme\":\"dark\"}", forKey: "app:user_preferences")
        let cache = EntitlementCache(storage: storage)
        await cache.setUserKey("alice")
        await cache.write(EntitlementSnapshot(developerUserId: "alice", entitlements: [entitlement("pro")]))

        await cache.clearAll()

        XCTAssertEqual(storage.getString("app:user_preferences"), "{\"theme\":\"dark\"}")
    }
}
