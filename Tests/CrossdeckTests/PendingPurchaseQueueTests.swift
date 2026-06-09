// Phase 1.2 contract tests — purchase durability on backend 5xx.
//
// Two surfaces under test:
//   1. PurchaseFinishDecision.shouldFinish — the pure encoding of
//      the "finish iff sync succeeded" bank-grade invariant. A
//      regression here would re-introduce the silent revenue-loss
//      bug fixed in v1.4.0.
//   2. PendingPurchaseQueue — the persistent retry buffer. Backoff
//      schedule, attempt cap, success/failure transitions, and
//      cross-instance durability via MemoryStorage round-trip.

import XCTest
@testable import Crossdeck

final class PendingPurchaseQueueTests: XCTestCase {

    // MARK: - PurchaseFinishDecision (the core invariant)

    func test_shouldFinish_isTrueOnSuccess() {
        XCTAssertTrue(PurchaseFinishDecision.shouldFinish(syncResult: .success(())))
    }

    func test_shouldFinish_isFalseOnAnyFailure() {
        let err = CrossdeckError(
            type: .internalError,
            code: "auto_purchase_sync_failed",
            message: "5xx from backend.",
            statusCode: 503
        )
        XCTAssertFalse(PurchaseFinishDecision.shouldFinish(syncResult: .failure(err)))
    }

    func test_shouldFinish_isFalseOn4xx() {
        // 4xx is permanent but still must NOT finish — the caller
        // surfaces the typed error via the purchase.sync_failed
        // event; finishing here would close the StoreKit feedback
        // loop without the backend ever having acknowledged the
        // purchase.
        let err = CrossdeckError(
            type: .invalidRequest,
            code: "invalid_jws",
            message: "Apple JWS verification failed.",
            statusCode: 400
        )
        XCTAssertFalse(PurchaseFinishDecision.shouldFinish(syncResult: .failure(err)))
    }

    func test_shouldFinish_isFalseOnNetworkError() {
        let err = CrossdeckError(
            type: .network,
            code: "transport_error",
            message: "Network unreachable.",
            statusCode: nil
        )
        XCTAssertFalse(PurchaseFinishDecision.shouldFinish(syncResult: .failure(err)))
    }

    // MARK: - PendingPurchaseQueue persistence

    func test_emptyQueue_loadsEmpty() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        let entries = await q.load()
        XCTAssertEqual(entries.count, 0)
    }

    func test_recordFailure_persistsEntryWithBackoff() async {
        let storage = MemoryStorage()
        let q = PendingPurchaseQueue(storage: storage)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let entry = await q.recordFailure(
            originalTransactionId: "1000000111",
            jws: "eyJqd3MtdGVzdC0xfQ==",
            now: now
        )

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.attempts, 1)
        XCTAssertEqual(entry?.originalTransactionId, "1000000111")
        XCTAssertEqual(
            entry!.nextRetryAt.timeIntervalSince(now),
            PendingPurchaseQueue.backoffSchedule[0],
            accuracy: 0.001,
            "First retry must use the first backoff slot (30s)"
        )

        // Survives a fresh queue instance (UserDefaults round-trip
        // analogue via MemoryStorage).
        let q2 = PendingPurchaseQueue(storage: storage)
        let reloaded = await q2.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.attempts, 1)
        XCTAssertEqual(reloaded.first?.originalTransactionId, "1000000111")
    }

    func test_recordFailure_incrementsAttempts_andAdvancesBackoff() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for attempt in 1...PendingPurchaseQueue.maxAttempts {
            let entry = await q.recordFailure(
                originalTransactionId: "tx_a",
                jws: "jws_a",
                now: now
            )
            XCTAssertNotNil(entry, "Attempt \(attempt) within cap MUST return an entry")
            XCTAssertEqual(entry?.attempts, attempt)
            let expectedBackoff = PendingPurchaseQueue.backoffSchedule[min(attempt - 1, PendingPurchaseQueue.backoffSchedule.count - 1)]
            XCTAssertEqual(
                entry!.nextRetryAt.timeIntervalSince(now),
                expectedBackoff,
                accuracy: 0.001
            )
        }
    }

    func test_recordFailure_dropsEntryAtCap() async {
        let storage = MemoryStorage()
        let q = PendingPurchaseQueue(storage: storage)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Fire failures up to + 1 over the cap.
        for _ in 0..<(PendingPurchaseQueue.maxAttempts + 1) {
            _ = await q.recordFailure(
                originalTransactionId: "tx_cap",
                jws: "jws_cap",
                now: now
            )
        }

        let entries = await q.load()
        XCTAssertEqual(
            entries.count, 0,
            "Beyond maxAttempts the entry MUST be dropped — StoreKit re-delivery takes over"
        )
    }

    func test_recordFailure_preservesFirstFailedAt() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)

        _ = await q.recordFailure(originalTransactionId: "tx_b", jws: "j", now: t0)
        let second = await q.recordFailure(originalTransactionId: "tx_b", jws: "j", now: t1)

        XCTAssertEqual(second?.firstFailedAt, t0, "firstFailedAt locks on initial failure")
    }

    func test_recordSuccess_clearsEntry() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        _ = await q.recordFailure(originalTransactionId: "tx_c", jws: "j")

        await q.recordSuccess(originalTransactionId: "tx_c")

        let entries = await q.load()
        XCTAssertEqual(entries.count, 0)
    }

    func test_dueEntries_filtersByNow() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await q.recordFailure(originalTransactionId: "tx_due", jws: "j1", now: t0)
        // First entry's nextRetryAt is t0 + 30s.

        let nothingDueYet = await q.dueEntries(now: t0)
        XCTAssertEqual(nothingDueYet.count, 0, "Entry whose nextRetryAt is in the future is NOT due")

        let dueLater = await q.dueEntries(now: t0.addingTimeInterval(60))
        XCTAssertEqual(dueLater.count, 1, "Entry whose nextRetryAt has elapsed IS due")
        XCTAssertEqual(dueLater.first?.originalTransactionId, "tx_due")
    }

    func test_multipleEntries_isolatedByTransactionId() async {
        let q = PendingPurchaseQueue(storage: MemoryStorage())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await q.recordFailure(originalTransactionId: "tx_x", jws: "jx", now: now)
        _ = await q.recordFailure(originalTransactionId: "tx_y", jws: "jy", now: now)
        _ = await q.recordFailure(originalTransactionId: "tx_x", jws: "jx", now: now)

        let entries = await q.load()
        XCTAssertEqual(entries.count, 2)
        let xEntry = entries.first(where: { $0.originalTransactionId == "tx_x" })
        let yEntry = entries.first(where: { $0.originalTransactionId == "tx_y" })
        XCTAssertEqual(xEntry?.attempts, 2, "tx_x failed twice")
        XCTAssertEqual(yEntry?.attempts, 1, "tx_y failed once and is not affected by tx_x's failures")
    }

    func test_emptyQueue_afterClear_removesPersistenceKey() async {
        let storage = MemoryStorage()
        let q = PendingPurchaseQueue(storage: storage)
        _ = await q.recordFailure(originalTransactionId: "tx_d", jws: "j")
        XCTAssertNotNil(storage.getString("pending_purchase_sync_v1"))

        await q.recordSuccess(originalTransactionId: "tx_d")
        XCTAssertNil(
            storage.getString("pending_purchase_sync_v1"),
            "Empty queue MUST remove the persistence key — no orphan empty JSON"
        )
    }
}
