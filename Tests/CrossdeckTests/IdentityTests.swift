import XCTest
@testable import Crossdeck

final class IdentityTests: XCTestCase {
    func test_generatesAnonymousId_onFirstLaunch() async {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        let snap = await identity.snapshot()
        XCTAssertTrue(snap.anonymousId.hasPrefix("cdanon_"))
        XCTAssertNil(snap.customerId)
    }

    func test_persistsAnonymousId_acrossInstances() async {
        let storage = MemoryStorage()
        let first = Identity(storage: storage)
        let firstId = await first.snapshot().anonymousId

        let second = Identity(storage: storage)
        let secondId = await second.snapshot().anonymousId

        XCTAssertEqual(firstId, secondId)
    }

    func test_setCustomerId_isIdempotent() async {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        let first = await identity.setCustomerId("u_1")
        let second = await identity.setCustomerId("u_1")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let snap = await identity.snapshot()
        XCTAssertEqual(snap.customerId, "u_1")
    }

    func test_setCustomerId_normalisesWhitespace_andNilsEmpty() async {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        _ = await identity.setCustomerId("  u_1  ")
        var snap = await identity.snapshot()
        XCTAssertEqual(snap.customerId, "u_1")

        _ = await identity.setCustomerId("")
        snap = await identity.snapshot()
        XCTAssertNil(snap.customerId)
    }

    func test_reset_regeneratesAnonymousId_andClearsCustomer() async {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        _ = await identity.setCustomerId("u_1")
        let before = await identity.snapshot()

        await identity.reset()
        let after = await identity.snapshot()

        XCTAssertNotEqual(before.anonymousId, after.anonymousId)
        XCTAssertNil(after.customerId)
    }
}
