// PendingPurchaseQueue — bank-grade purchase-durability retry buffer.
//
// Phase 1.2 of bank-grade reconciliation v1.4.0. The pre-1.4.0
// PurchaseAutoTrack.handle path called `transaction.finish()`
// regardless of whether the backend `/purchases/sync` succeeded —
// a mid-process-death + 5xx combo silently lost the purchase.
//
// This queue is the durable retry buffer. When a sync attempt
// fails, the JWS + originalTransactionId are persisted to
// UserDefaults (via the SDK's Storage protocol) with the next
// retry timestamp. A background drain task on
// `PurchaseAutoTrack.start()` wakes periodically, finds entries
// whose `nextRetryAt` has elapsed, and re-attempts the sync.
//
// Bank-grade invariants:
//   * The transaction is NEVER `.finish()`ed until the backend
//     has 2xx-acknowledged the sync. StoreKit continues to
//     re-deliver the unfinished transaction on every launch so a
//     retry path always exists, even when this in-process queue
//     gives up.
//   * Bounded retries (max 5 attempts) prevent infinite in-process
//     retry loops. On the 6th attempt we DROP the queue entry but
//     STILL leave the transaction unfinished — StoreKit's
//     re-delivery on the next session takes over.
//   * Exponential backoff (30s, 1m, 5m, 30m, 2h) gives a
//     transient backend outage time to recover without burning
//     the retry budget.
//   * Persistence layer is the shared SDK `Storage` (UserDefaults
//     by default, MemoryStorage in tests) so the queue survives
//     process restarts.

import Foundation

/// One queued purchase awaiting backend acknowledgement. `Codable`
/// so the queue can round-trip the entire snapshot through
/// `Storage.getString` / `setString`.
public struct PendingPurchaseEntry: Codable, Equatable, Sendable {
    public let originalTransactionId: String
    public let jws: String
    public let firstFailedAt: Date
    public let attempts: Int
    public let nextRetryAt: Date

    public init(
        originalTransactionId: String,
        jws: String,
        firstFailedAt: Date,
        attempts: Int,
        nextRetryAt: Date
    ) {
        self.originalTransactionId = originalTransactionId
        self.jws = jws
        self.firstFailedAt = firstFailedAt
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
    }
}

/// Persistent retry queue for StoreKit transactions whose
/// `/purchases/sync` round-trip failed. Backed by the SDK's
/// `Storage` abstraction so tests can swap in `MemoryStorage`.
public actor PendingPurchaseQueue {
    /// Hard cap on in-process retry attempts. Beyond this we DROP
    /// the queue entry but leave the StoreKit transaction
    /// unfinished — Apple's re-delivery on the next session is
    /// then the only retry path, which is the correct behaviour
    /// (don't pretend we know better than the platform).
    public static let maxAttempts: Int = 5

    /// Backoff in seconds for each attempt 1..maxAttempts. The
    /// final entry (2h) is applied to any attempt at or beyond
    /// the array bound, so a future bump of `maxAttempts` doesn't
    /// crash on an out-of-range index.
    public static let backoffSchedule: [TimeInterval] = [30, 60, 300, 1800, 7200]

    private let storage: Storage
    private let key: String

    public init(storage: Storage, key: String = "pending_purchase_sync_v1") {
        self.storage = storage
        self.key = key
    }

    /// Read the full queue from persistence. Returns an empty
    /// array if the key is absent or the JSON is corrupt — a
    /// corrupt entry is logically equivalent to an empty queue,
    /// and Apple's re-delivery will refill it on the next launch.
    public func load() -> [PendingPurchaseEntry] {
        guard let raw = storage.getString(key),
              let data = raw.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingPurchaseEntry].self, from: data)) ?? []
    }

    /// Replace the persisted queue with `entries`. An empty array
    /// removes the key entirely (avoids leaving an empty JSON
    /// array taking up UserDefaults space).
    public func save(_ entries: [PendingPurchaseEntry]) {
        if entries.isEmpty {
            storage.remove(key)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8) else { return }
        storage.setString(str, forKey: key)
    }

    /// Record a failed sync attempt. Returns the resulting entry
    /// (existing attempts + 1) or nil when the maxAttempts cap
    /// has been hit and the entry has been dropped.
    @discardableResult
    public func recordFailure(
        originalTransactionId: String,
        jws: String,
        now: Date = Date()
    ) -> PendingPurchaseEntry? {
        var entries = load()
        let existing = entries.first(where: { $0.originalTransactionId == originalTransactionId })
        let nextAttempts = (existing?.attempts ?? 0) + 1
        entries.removeAll(where: { $0.originalTransactionId == originalTransactionId })
        if nextAttempts > Self.maxAttempts {
            save(entries)
            return nil
        }
        let backoffIndex = min(nextAttempts - 1, Self.backoffSchedule.count - 1)
        let updated = PendingPurchaseEntry(
            originalTransactionId: originalTransactionId,
            jws: jws,
            firstFailedAt: existing?.firstFailedAt ?? now,
            attempts: nextAttempts,
            nextRetryAt: now.addingTimeInterval(Self.backoffSchedule[backoffIndex])
        )
        entries.append(updated)
        save(entries)
        return updated
    }

    /// Mark a transaction as successfully synced — removes the
    /// entry from the queue. No-op if the entry was never queued
    /// (success on the very first attempt).
    public func recordSuccess(originalTransactionId: String) {
        var entries = load()
        let countBefore = entries.count
        entries.removeAll(where: { $0.originalTransactionId == originalTransactionId })
        if entries.count != countBefore {
            save(entries)
        }
    }

    /// Drop an entry without recording success — used when the
    /// retry drain task discovers StoreKit no longer tracks the
    /// transaction (Apple-side reconciliation removed it).
    public func drop(originalTransactionId: String) {
        recordSuccess(originalTransactionId: originalTransactionId)
    }

    /// Entries whose `nextRetryAt` has elapsed and are eligible
    /// for another sync attempt right now.
    public func dueEntries(now: Date = Date()) -> [PendingPurchaseEntry] {
        load().filter { $0.nextRetryAt <= now }
    }

    /// Total count — exposed for tests + observability.
    public func count() -> Int {
        load().count
    }
}
