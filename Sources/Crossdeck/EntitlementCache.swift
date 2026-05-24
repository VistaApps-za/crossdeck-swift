// Entitlement cache.
//
// Stores the most recently fetched entitlement set for a customer,
// keyed by customerId so we don't accidentally serve a previous
// user's entitlements to a freshly-identified one. Acts as both:
//
//   * The synchronous answer source for `isEntitled(...)` (the
//     consumer cannot afford a network round-trip on a paywall
//     gate, so we hand back whatever we have).
//
//   * A subscriber broadcast so the UI can re-render when the
//     cache updates from a server fetch.
//
// Persistence: serialised to a single JSON blob with both the
// customerId and the set, so a launch with the same customerId
// gets a hot read; a launch with a different customerId (after
// reset() / re-identify) ignores the stored blob and starts cold.

import Foundation

public struct EntitlementSnapshot: Sendable, Equatable, Codable {
    public let customerId: String
    public let entitlements: Set<String>
    public let updatedAt: Date

    public init(customerId: String, entitlements: Set<String>, updatedAt: Date = Date()) {
        self.customerId = customerId
        self.entitlements = entitlements
        self.updatedAt = updatedAt
    }
}

public typealias EntitlementSubscriber = @Sendable (EntitlementSnapshot?) -> Void

public actor EntitlementCache {
    private let storage: Storage
    private let storageKey: String = "entitlements.snapshot"

    private var current: EntitlementSnapshot?
    private var subscribers: [UUID: EntitlementSubscriber] = [:]

    public init(storage: Storage) {
        self.storage = storage
        if let blob = storage.getString(storageKey),
           let data = blob.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EntitlementSnapshot.self, from: data) {
            self.current = decoded
        }
    }

    /// Synchronous accessor for the cached entitlement set scoped
    /// to a particular customer. Returns `nil` if no snapshot is
    /// stored, OR if the stored snapshot is for a DIFFERENT
    /// customer (which would mean we have stale data from a prior
    /// user). Callers should treat nil as "not yet known" — never
    /// as "definitely false".
    public func entitlements(for customerId: String) -> Set<String>? {
        guard let current, current.customerId == customerId else { return nil }
        return current.entitlements
    }

    /// Synchronous quick check. Same caveats as `entitlements(for:)`:
    /// returns false if no cache exists or it belongs to a different
    /// customer.
    public func isEntitled(_ key: String, for customerId: String) -> Bool {
        guard let set = entitlements(for: customerId) else { return false }
        return set.contains(key)
    }

    /// Replace the cached snapshot. Notifies subscribers if the new
    /// value differs from the old. Persists to storage.
    public func write(_ snapshot: EntitlementSnapshot) {
        let changed = (current != snapshot)
        current = snapshot

        if let data = try? JSONEncoder().encode(snapshot),
           let blob = String(data: data, encoding: .utf8) {
            storage.setString(blob, forKey: storageKey)
        }

        if changed {
            notifyAll()
        }
    }

    /// Wipe the cache. Called from `reset()` and from `identify(...)`
    /// when the new customerId differs from the old (so the old
    /// user's entitlements never leak across an account switch).
    public func clear() {
        guard current != nil else { return }
        current = nil
        storage.remove(storageKey)
        notifyAll()
    }

    /// Subscribe to changes. Returns a cancellation token; capture
    /// it in your view model and call `unsubscribe(_:)` to detach.
    public func subscribe(_ handler: @escaping EntitlementSubscriber) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        // Fire once on subscription so the consumer doesn't have to
        // independently read the current state.
        let snapshot = current
        Task.detached { handler(snapshot) }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func notifyAll() {
        let snapshot = current
        let handlers = Array(subscribers.values)
        for handler in handlers {
            Task.detached { handler(snapshot) }
        }
    }
}
