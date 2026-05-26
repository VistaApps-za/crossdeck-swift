// Entitlement cache.
//
// Stores the most recently fetched entitlement set for a customer
// scoped to their identity (developerUserId for v1.0.x; will swap
// to crossdeckCustomerId in v1.1 once /identity/alias persistence
// is wired). Two roles:
//
//   * Synchronous source for `isEntitled(...)` paywall gates —
//     consumers cannot afford a network round-trip on a tap handler.
//
//   * Subscriber broadcast so the UI can re-render when the cache
//     updates from a server fetch.
//
// **Bank-grade durability model (matches Web/Node/RN):**
//
//   * Persisted as a single JSON blob with both customerId AND set,
//     so a launch with the same customerId gets a hot read; a launch
//     with a different customerId ignores the stored blob and starts
//     cold.
//
//   * Per-entitlement `validUntil` honoured — a snapshot can be
//     fresh on the metadata level while a specific entitlement has
//     already expired. `isEntitled` checks both `isActive` AND
//     `validUntil > now`.
//
//   * Staleness model: `staleAfterMs` (default 60s) marks a snapshot
//     as stale even though it's still authoritative — UI can show a
//     refresh spinner. `markRefreshFailed()` records the timestamp
//     of the last failed refresh attempt so a Crossdeck outage
//     doesn't fail a paying customer down to free (last-known-good
//     wins; only a HARD permanent rejection clears the cache).

import Foundation

/// Default staleness window — 60s matches the Web/Node/RN platform
/// contract. Snapshots older than this are surfaced as `isStale`
/// for UI refresh hints, but `isEntitled` still honours them.
public let defaultEntitlementStaleAfterMs: Int64 = 60_000

/// Snapshot of the entitlement cache for a single user identity.
public struct EntitlementSnapshot: Sendable, Equatable, Codable {
    /// The identity these entitlements belong to. v1.0.x: the
    /// developerUserId; v1.1+: will swap to crossdeckCustomerId.
    public let developerUserId: String
    public let entitlements: [PublicEntitlement]
    /// Epoch ms when the cache was last populated by a successful
    /// `GET /entitlements` or `POST /purchases/sync`.
    public let lastUpdated: Int64
    /// Epoch ms of the last failed refresh attempt. Used by the
    /// staleness model — a paying customer never gets failed down
    /// to free during a transient outage; only a successful refresh
    /// can replace the cache.
    public let lastRefreshFailedAt: Int64?

    public init(
        developerUserId: String,
        entitlements: [PublicEntitlement],
        lastUpdated: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        lastRefreshFailedAt: Int64? = nil
    ) {
        self.developerUserId = developerUserId
        self.entitlements = entitlements
        self.lastUpdated = lastUpdated
        self.lastRefreshFailedAt = lastRefreshFailedAt
    }
}

public typealias EntitlementSubscriber = @Sendable (EntitlementSnapshot?) -> Void

/// Sync-readable box for the latest entitlement snapshot.
///
/// The `EntitlementCache` actor is the source of truth for writes,
/// but paywall gates need to query "is this customer entitled?" on
/// the caller's thread — and a Swift actor cannot offer a fully
/// synchronous read from a non-isolated context. We mirror the
/// actor's current state into an `NSLock`-protected box. The actor
/// writes through the box on every mutation; sync readers
/// (`Crossdeck.isEntitled`) read from it without ever touching
/// the actor.
final class EntitlementSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EntitlementSnapshot?

    func read() -> EntitlementSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func write(_ snapshot: EntitlementSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        value = snapshot
    }
}

/// Thread-safe Sendable box for the per-user storage suffix.
/// Sits alongside the actor so nonisolated entry points (the
/// sync `identify(...)` path) can read the active suffix without
/// crossing the actor boundary.
final class CurrentSuffixBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ initial: String) { self.value = initial }
    func read() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func write(_ v: String) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }
}

public actor EntitlementCache {
    /// v1.4.x bank-grade per-user storage isolation. Mirrors the
    /// Web/RN/Android implementation: each user's cache blob lives
    /// under `crossdeck:entitlements:<sha256(userId)>`, and an
    /// index blob tracks every suffix written so `clearAll()`
    /// (used by `Crossdeck.reset()`) can wipe every per-user slot
    /// on the device — not just the active user's.
    private static let keyPrefix = "crossdeck:entitlements"
    private static let anonSuffix = "_anon"
    private static let indexSuffix = "_index"

    private let storage: Storage
    private let staleAfterMs: Int64

    private var current: EntitlementSnapshot?
    private var subscribers: [UUID: EntitlementSubscriber] = [:]
    private let syncBox = EntitlementSnapshotBox()

    /// Active per-user suffix — stored in a thread-safe box so
    /// the nonisolated `storageKey` getter can read it from sync
    /// entry points (`Crossdeck.identify(...)` is sync and calls
    /// `setUserKeySync(...)` on this cache). Defaults to the
    /// anonymous slot; flipped via `setUserKey(_:)` /
    /// `setUserKeySync(_:)`.
    private let suffixBox: CurrentSuffixBox

    /// Computed full storage key for the active suffix. Reads
    /// through the thread-safe box so it's safe from any context.
    private nonisolated var storageKey: String { "\(Self.keyPrefix):\(suffixBox.read())" }

    /// Index storage key — JSON array of every suffix the cache
    /// has written. Used by `clearAll()` to scope the logout-wipe.
    private nonisolated var indexKey: String { "\(Self.keyPrefix):\(Self.indexSuffix)" }

    public init(storage: Storage, staleAfterMs: Int64 = defaultEntitlementStaleAfterMs) {
        self.storage = storage
        self.staleAfterMs = staleAfterMs
        self.suffixBox = CurrentSuffixBox(Self.anonSuffix)
        // Hydrate from the anonymous slot on construction. After
        // identify() flips the suffix via setUserKey()/setUserKeySync(),
        // subsequent boots that hydrate at the anonymous slot will be
        // empty (the prior identified user's blob is at their per-
        // user key, which only loads after the next identify(userId)
        // re-flips the suffix).
        let initialKey = "\(Self.keyPrefix):\(Self.anonSuffix)"
        if let blob = storage.getString(initialKey),
           let data = blob.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EntitlementSnapshot.self, from: data) {
            self.current = decoded
            self.syncBox.write(decoded)
        }
    }

    /// Derive a stable suffix for a developerUserId via SHA-256.
    /// Reuses `IdempotencyKey.sha256Hex` so the SDK ships a single
    /// hash impl. Empty/nil → anonymous slot.
    nonisolated static func suffixForUserId(_ userId: String?) -> String {
        guard let id = userId, !id.isEmpty else { return anonSuffix }
        return IdempotencyKey.sha256Hex(id)
    }

    /// v1.4.x bank-grade three-layer entitlement-cache isolation
    /// (mirrors Web/RN/Android):
    ///   (a) Physical key separation — `crossdeck:entitlements:<sha256>`.
    ///   (b) Unconditional in-memory clear — every identify() flips
    ///       the suffix even on same-id re-identify.
    ///   (c) Re-hydrate from the new slot — returning user observes
    ///       their last-known-good cache immediately.
    ///
    /// Caller (`Crossdeck.identify()` / `reset()`) MUST `await` this
    /// BEFORE the next `write()` so the persisted blob lands under
    /// the right key.
    public func setUserKey(_ userId: String?) {
        let nextSuffix = Self.suffixForUserId(userId)
        suffixBox.write(nextSuffix)
        current = nil
        syncBox.write(nil)
        // Re-hydrate from the new slot.
        if let blob = storage.getString(storageKey),
           let data = blob.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EntitlementSnapshot.self, from: data) {
            current = decoded
            syncBox.write(decoded)
        }
        notifyAll()
    }

    /// Sync entry point for the suffix flip — used by the sync
    /// `Crossdeck.identify()` path. Updates the suffix box + the
    /// syncBox snapshot synchronously so an `isEntitled(...)` call
    /// on the next line cannot observe the prior user's cache.
    /// The async reconciliation re-hydrates from the new slot in
    /// a detached Task (matches the clearSync → reconcileClearFromSync
    /// pattern already in the file).
    public nonisolated func setUserKeySync(_ userId: String?) {
        let nextSuffix = Self.suffixForUserId(userId)
        suffixBox.write(nextSuffix)
        syncBox.write(nil)
        Task { await self.reconcileSetUserKeyFromSync() }
    }

    private func reconcileSetUserKeyFromSync() {
        current = nil
        if let blob = storage.getString(storageKey),
           let data = blob.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EntitlementSnapshot.self, from: data) {
            current = decoded
            syncBox.write(decoded)
        }
        notifyAll()
    }

    // MARK: - Sync reads

    /// Nonisolated sync check. True iff the cache has an active
    /// entitlement for this key AND its `validUntil` (if set)
    /// hasn't passed. Returns false for an unknown key, an expired
    /// key, or when the cache belongs to a different customer.
    public nonisolated func isEntitledSync(
        _ key: String,
        for developerUserId: String
    ) -> Bool {
        guard let snap = syncBox.read(), snap.developerUserId == developerUserId else {
            return false
        }
        guard let ent = snap.entitlements.first(where: { $0.key == key }) else {
            return false
        }
        if !ent.isActive { return false }
        if let until = ent.validUntil {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if nowMs > until { return false }
        }
        return true
    }

    /// Nonisolated sync read of the full entitlement list for this
    /// customer. Returns nil if no snapshot exists or it belongs to
    /// a different customer. Filters out expired entries.
    public nonisolated func entitlementsSync(
        for developerUserId: String
    ) -> [PublicEntitlement]? {
        guard let snap = syncBox.read(), snap.developerUserId == developerUserId else {
            return nil
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return snap.entitlements.filter { ent in
            if !ent.isActive { return false }
            if let until = ent.validUntil, nowMs > until { return false }
            return true
        }
    }

    /// Freshness diagnostic — exposed via `Crossdeck.diagnostics()`.
    /// Returns nil when no cache exists.
    public nonisolated func freshness() -> (
        lastUpdated: Int64,
        isStale: Bool,
        lastRefreshFailedAt: Int64?
    )? {
        guard let snap = syncBox.read() else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ageMs = nowMs - snap.lastUpdated
        return (snap.lastUpdated, ageMs > staleAfterMs, snap.lastRefreshFailedAt)
    }

    // MARK: - Mutations

    /// Replace the cached snapshot with a fresh fetch. Persists to
    /// storage, updates sync mirror, notifies subscribers.
    public func write(_ snapshot: EntitlementSnapshot) {
        let changed = (current != snapshot)
        current = snapshot
        syncBox.write(snapshot)

        if let data = try? JSONEncoder().encode(snapshot),
           let blob = String(data: data, encoding: .utf8) {
            storage.setString(blob, forKey: storageKey)
        }
        recordSuffixInIndex(suffixBox.read())

        if changed {
            notifyAll()
        }
    }

    // MARK: - Per-user suffix index (v1.4.x bank-grade isolation)

    /// Read the index of all per-user suffixes the cache has written.
    private func readIndex() -> [String] {
        guard let raw = storage.getString(indexKey),
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    /// Add a suffix to the persisted index. Idempotent.
    private func recordSuffixInIndex(_ suffix: String) {
        var existing = readIndex()
        if existing.contains(suffix) { return }
        existing.append(suffix)
        if let data = try? JSONEncoder().encode(existing),
           let blob = String(data: data, encoding: .utf8) {
            storage.setString(blob, forKey: indexKey)
        }
    }

    /// Remove a suffix from the persisted index. No-op if absent.
    private func removeSuffixFromIndex(_ suffix: String) {
        let existing = readIndex()
        let next = existing.filter { $0 != suffix }
        if next.count == existing.count { return }
        if next.isEmpty {
            storage.remove(indexKey)
        } else if let data = try? JSONEncoder().encode(next),
                  let blob = String(data: data, encoding: .utf8) {
            storage.setString(blob, forKey: indexKey)
        }
    }

    /// Update the in-place snapshot to record a failed refresh
    /// attempt WITHOUT invalidating the cache. Bank-grade rule:
    /// a Crossdeck outage MUST NOT fail a paying customer down to
    /// free. Only a successful refresh can replace the entitlement
    /// set. Records the failure timestamp so UI can render a
    /// "last-checked at" badge.
    public func markRefreshFailed() {
        guard let existing = current else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let updated = EntitlementSnapshot(
            developerUserId: existing.developerUserId,
            entitlements: existing.entitlements,
            lastUpdated: existing.lastUpdated,
            lastRefreshFailedAt: nowMs
        )
        current = updated
        syncBox.write(updated)
        if let data = try? JSONEncoder().encode(updated),
           let blob = String(data: data, encoding: .utf8) {
            storage.setString(blob, forKey: storageKey)
        }
    }

    /// Wipe the CURRENT user's cache slot only. Used internally
    /// when a single user's cache needs invalidation. The full
    /// logout-grade path is [[clearAll]].
    public func clear() {
        guard current != nil else {
            syncBox.write(nil)
            return
        }
        current = nil
        syncBox.write(nil)
        storage.remove(storageKey)
        removeSuffixFromIndex(suffixBox.read())
        notifyAll()
    }

    /// Logout-grade wipe — bank-grade contract: removes EVERY
    /// per-user entitlement slot the SDK has written on this
    /// device (via the persisted suffix index), plus the anonymous
    /// slot + the index itself. Used by `Crossdeck.reset()` so a
    /// logout on a shared device can never leave another user's
    /// entitlements readable.
    ///
    /// After clearAll(), the cache is back to anonymous + empty.
    public func clearAll() {
        let suffixes = readIndex()
        for s in suffixes {
            storage.remove("\(Self.keyPrefix):\(s)")
        }
        // Belt-and-suspenders — anonymous slot might not be indexed
        // if it was cleared before its first write.
        storage.remove("\(Self.keyPrefix):\(Self.anonSuffix)")
        storage.remove(indexKey)
        current = nil
        syncBox.write(nil)
        suffixBox.write(Self.anonSuffix)
        notifyAll()
    }

    /// Nonisolated sync clear — used by `Crossdeck.identify(...)` to
    /// wipe the cache atomically with the customerId swap.
    public nonisolated func clearSync() {
        syncBox.write(nil)
        storage.remove(storageKey)
        Task { await self.reconcileClearFromSync() }
    }

    private func reconcileClearFromSync() {
        guard current != nil else { return }
        current = nil
        notifyAll()
    }

    /// Subscribe to changes. Returns a cancellation token.
    /// Does NOT fire on subscribe (matches Web/Node/RN — read the
    /// current value via `Crossdeck.entitlementsForCurrentCustomer()`
    /// for the initial render).
    public func subscribe(_ handler: @escaping EntitlementSubscriber) -> UUID {
        let token = UUID()
        subscribers[token] = handler
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
