import XCTest
@testable import Crossdeck

/// The CURRENT appAccountToken contract (v1.5.0+): `ensureAppAccountTokenSync()`
/// mints a fresh random UUID on first call, persists it under
/// `apple_app_account_token`, returns the identical value on every later call
/// regardless of identity changes, and `reset()` wipes it so the next
/// purchasing entity on the device mints its own.
///
/// The deprecated v1.4.x derive-from-developerUserId path is pinned separately
/// in `AppAccountTokenDerivationTests` (regression coverage for code that must
/// never be resurrected). These tests cover the path production code actually
/// calls — see `contracts/revenue/appaccounttoken-uuid-conformance.json`.
final class AppAccountTokenLifecycleTests: XCTestCase {

    /// Mint waits for the actor to reconcile from the sync mirror so
    /// `snapshot()` assertions are deterministic.
    private func awaitReconcile(_ identity: Identity, expected: String?) async {
        for _ in 0..<200 {
            let snap = await identity.snapshot()
            if snap.appAccountToken == expected { return }
            await Task.yield()
        }
    }

    // (1) First call mints a valid RFC 4122 UUID.

    func test_firstCall_mintsValidLowercaseUUID() {
        let identity = Identity(storage: MemoryStorage())
        let token = identity.ensureAppAccountTokenSync()
        XCTAssertNotNil(UUID(uuidString: token), "minted token must be a valid RFC 4122 UUID")
        XCTAssertEqual(token, token.lowercased(), "canonical wire form is lowercase")
    }

    func test_tokenIsLazy_neverMintedBeforeFirstEnsureCall() {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        XCTAssertNil(identity.appAccountTokenSync(), "no token before the purchase path asks for one")
        XCTAssertNil(storage.getString("apple_app_account_token"), "nothing persisted before first mint")
    }

    // (2) Subsequent calls return the identical value — across identify()
    //     and any identity mutation short of reset(). This is the property
    //     the deprecated derivation lacked (Shape 2).

    func test_subsequentCalls_returnSameValue_acrossIdentityChanges() async {
        let identity = Identity(storage: MemoryStorage())
        let beforeLogin = identity.ensureAppAccountTokenSync()

        _ = await identity.setDeveloperUserId("u_anonymous_becomes_real")
        let afterLogin = identity.ensureAppAccountTokenSync()

        _ = await identity.setDeveloperUserId("u_after_sso_merge")
        let afterMerge = identity.ensureAppAccountTokenSync()

        XCTAssertEqual(beforeLogin, afterLogin, "login must not change the token")
        XCTAssertEqual(beforeLogin, afterMerge, "identity merge must not change the token")
    }

    // (3) Value persists across SDK restart — a new Identity over the same
    //     storage reads the minted token instead of minting again.

    func test_persistsAcrossInstances_reinitReadsStorage() {
        let storage = MemoryStorage()
        let minted = Identity(storage: storage).ensureAppAccountTokenSync()

        let relaunched = Identity(storage: storage)
        XCTAssertEqual(relaunched.appAccountTokenSync(), minted, "restart reads the persisted token")
        XCTAssertEqual(relaunched.ensureAppAccountTokenSync(), minted, "ensure after restart must not re-mint")
    }

    // (4) reset() wipes the token; the next call mints a DIFFERENT UUID.
    //     Wipe-on-reset is the load-bearing property: token lifetime tracks
    //     purchasing-entity lifetime.

    func test_reset_wipesToken_andNextCallMintsFreshUUID() async {
        let storage = MemoryStorage()
        let identity = Identity(storage: storage)
        let firstUser = identity.ensureAppAccountTokenSync()
        await awaitReconcile(identity, expected: firstUser)

        await identity.reset()
        XCTAssertNil(identity.appAccountTokenSync(), "reset wipes the live token")
        XCTAssertNil(storage.getString("apple_app_account_token"), "reset wipes the persisted token")

        let secondUser = identity.ensureAppAccountTokenSync()
        XCTAssertNotNil(UUID(uuidString: secondUser))
        XCTAssertNotEqual(firstUser, secondUser, "the next purchasing entity gets its own token")
    }

    // (5) The token rides on identify()'s alias request. identify() builds
    //     its body from the identity snapshot — token present IFF a purchase
    //     flow already minted one, and identify() itself never mints.

    func test_snapshotCarriesMintedToken_butIdentifyNeverMints() async {
        let identity = Identity(storage: MemoryStorage())

        let before = await identity.snapshot()
        XCTAssertNil(before.appAccountToken, "identify() must not invent a token for purchase-free installs")

        let minted = identity.ensureAppAccountTokenSync()
        await awaitReconcile(identity, expected: minted)
        let after = await identity.snapshot()
        XCTAssertEqual(after.appAccountToken, minted, "alias body source carries the minted token")
    }

    func test_aliasRequest_encodesAppAccountToken_onTheWire() throws {
        let token = "0f4b9a3e-7c2d-4e8f-9a1b-3c5d7e9f0a2b"
        let body = AliasIdentityRequest(
            userId: "u_1",
            anonymousId: "anon_x",
            email: nil,
            traits: nil,
            appAccountToken: token
        )
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        XCTAssertTrue(json.contains("\"appAccountToken\":\"\(token)\""), "token must serialise on the alias wire payload")
    }
}
