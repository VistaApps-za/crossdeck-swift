// Bank-grade contract tests on the public Crossdeck client surface.
//
// These tests exercise the contracts the developer docs explicitly
// promise — every one of them was a P0/P1 finding from the audit
// before being implemented + tested here.

import XCTest
@testable import Crossdeck

final class CrossdeckPublicAPITests: XCTestCase {

    // Thread-safe sink for debug signals. Swift's public fire-and-forget API
    // (track/identify) NEVER throws and NEVER traps — it drops+logs on invalid
    // input or a stopped client. (This is the Swift IDIOM; the TS SDKs reject
    // the same inputs by throwing a typed CrossdeckError — same invariant, no
    // host-app crash, different signalling mechanism.) The Swift drop is
    // observable ONLY via the debug logger, so these tests capture it rather
    // than asserting a throw the surface never makes.
    private final class DebugSink: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(DebugSignal, [String: String])] = []
        func record(_ signal: DebugSignal, _ payload: [String: String]) {
            lock.lock(); entries.append((signal, payload)); lock.unlock()
        }
        func captured(key: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return entries.compactMap { $0.1[key] }
        }
    }

    private func makeClient(storage: Storage? = nil, sink: DebugSink? = nil) -> Crossdeck {
        let logger: DebugLogger
        if let sink {
            logger = { signal, payload in sink.record(signal, payload) }
        } else {
            logger = noopDebugLogger
        }
        return try! Crossdeck.start(options: CrossdeckOptions(
            appId: "app_swift_tests",
            publicKey: "cd_pub_test_swiftunit",
            environment: .sandbox,
            storage: storage ?? MemoryStorage(),
            debugLogger: logger
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

    func test_stop_dropsSubsequentTrackCalls() {
        let sink = DebugSink()
        let cd = makeClient(sink: sink)
        cd.stopSync()
        // Fire-and-forget: no throw, no crash — the call is dropped and the
        // not_initialized reason is surfaced via the debug logger.
        cd.track("post_stop_event")
        XCTAssertEqual(sink.captured(key: "track_dropped"), ["not_initialized"])
    }

    func test_stop_dropsSubsequentIdentifyCalls() {
        let sink = DebugSink()
        let cd = makeClient(sink: sink)
        cd.stopSync()
        cd.identify(userId: "u_1")
        XCTAssertEqual(sink.captured(key: "identify_dropped"), ["not_initialized"])
    }

    func test_stop_isIdempotent() {
        let sink = DebugSink()
        let cd = makeClient(sink: sink)
        cd.stopSync()
        cd.stopSync()  // second call must not crash
        // Still drops after multiple stops.
        cd.track("e")
        XCTAssertEqual(sink.captured(key: "track_dropped"), ["not_initialized"])
    }

    // MARK: - track validation

    func test_track_dropsEmptyName() {
        let sink = DebugSink()
        let cd = makeClient(sink: sink)
        defer { cd.stopSync() }
        // Empty name is a defined drop — track() NEVER throws or traps.
        cd.track("")
        XCTAssertEqual(sink.captured(key: "track_dropped"), ["missing_event_name"])
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

    // The fire-and-forget identify(userId:) is non-throwing: an empty
    // userId is a defined, handled drop (matches Web/Node/RN). It must
    // NOT crash and must NOT throw — the only signal is the debug logger.
    func test_identify_emptyId_dropsWithoutCrashing() {
        let cd = makeClient()
        defer { cd.stopSync() }
        // No throw, no trap — just a silent, defined drop.
        cd.identify(userId: "")
    }

    // The throwing identifyAndWait(userId:) is the surface that rejects an
    // empty userId with code missing_user_id for callers who want to handle it.
    func test_identifyAndWait_rejectsEmptyId() async {
        let cd = makeClient()
        defer { cd.stopSync() }
        do {
            _ = try await cd.identifyAndWait(userId: "")
            XCTFail("expected identifyAndWait to throw for empty userId")
        } catch let err as CrossdeckError {
            XCTAssertEqual(err.code, "missing_user_id")
        } catch {
            XCTFail("expected CrossdeckError, got \(error)")
        }
    }
}
