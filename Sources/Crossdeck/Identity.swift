// Identity actor.
//
// Owns the lifecycle of the THREE canonical identity primitives
// across process restarts:
//
//   * `anonymousId` — device handle, minted on first launch,
//     persisted across restarts, regenerated only by `reset()`.
//     Sent on every event so the server can attribute pre-identify
//     analytics into the now-known person via merge.
//
//   * `developerUserId` — the consumer's auth-provider user ID
//     (Firebase Auth's `uid`, Auth0's `sub`, Supabase's `id`, …).
//     Passed in as the first arg to `identify(userId:...)`. NEVER
//     confuse this with `crossdeckCustomerId` (`cdcust_…`) — they're
//     different concept spaces.
//
//   * `crossdeckCustomerId` — the canonical Crossdeck-side record
//     handle (`cdcust_…`) returned from `/identity/alias`. Persisted
//     across launches so the cdcust survives partial-storage-wipe
//     scenarios where the developerUserId was evicted but our value
//     survived. Stamped on every event hint when known so the
//     server-side dedup target is unambiguous.
//
// Concurrency: actor-isolated, with NSLock-protected sync mirror
// box for paywall reads that can't pay an actor hop.

import Foundation

public struct IdentitySnapshot: Sendable, Equatable {
    public let anonymousId: String
    public let developerUserId: String?
    public let crossdeckCustomerId: String?

    public init(
        anonymousId: String,
        developerUserId: String?,
        crossdeckCustomerId: String?
    ) {
        self.anonymousId = anonymousId
        self.developerUserId = developerUserId
        self.crossdeckCustomerId = crossdeckCustomerId
    }
}

/// NSLock-protected mirror of the identity trio, kept in sync with
/// the actor on every mutation. Lets paywall reads (and the error
/// pipeline) read the current identity on the caller's thread
/// without an actor hop.
final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: IdentitySnapshot

    init(
        anonymousId: String,
        developerUserId: String?,
        crossdeckCustomerId: String?
    ) {
        self.snapshot = IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: developerUserId,
            crossdeckCustomerId: crossdeckCustomerId
        )
    }

    func read() -> IdentitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func write(_ next: IdentitySnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshot = next
    }
}

public actor Identity {
    private let storage: Storage

    /// Storage keys MATCH the canonical Web/RN convention exactly so a
    /// cross-SDK migration tool can read either side's persisted state.
    private let anonymousIdKey: String = "anon_id"
    private let developerUserIdKey: String = "developer_user_id"
    private let crossdeckCustomerIdKey: String = "cdcust_id"

    public private(set) var anonymousId: String
    public private(set) var developerUserId: String?
    public private(set) var crossdeckCustomerId: String?

    /// Sync-readable mirror, updated on every mutation. Exposed via
    /// `nonisolated` snapshot for fast paywall reads.
    private let syncBox: IdentityBox

    /// Designated initialiser. Reads existing identity from storage;
    /// if no anonymousId is stored, generates one and persists it
    /// before returning. Every Identity instance starts life with a
    /// non-nil anonymousId — callers never need to handle "what if
    /// there's no id yet" branches.
    public init(storage: Storage) {
        self.storage = storage
        let storedAnon = storage.getString(anonymousIdKey)
        let initialAnon: String
        if let storedAnon, !storedAnon.isEmpty {
            initialAnon = storedAnon
        } else {
            initialAnon = Identity.makeAnonymousId()
            storage.setString(initialAnon, forKey: anonymousIdKey)
        }
        self.anonymousId = initialAnon
        let initialDev = storage.getString(developerUserIdKey).flatMap { $0.isEmpty ? nil : $0 }
        self.developerUserId = initialDev
        let initialCdcust = storage.getString(crossdeckCustomerIdKey).flatMap { $0.isEmpty ? nil : $0 }
        self.crossdeckCustomerId = initialCdcust
        self.syncBox = IdentityBox(
            anonymousId: initialAnon,
            developerUserId: initialDev,
            crossdeckCustomerId: initialCdcust
        )
    }

    /// Set the developerUserId. Idempotent — calling with the same
    /// id twice is a no-op (no storage write).
    public func setDeveloperUserId(_ id: String?) -> Bool {
        let normalised = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = (normalised?.isEmpty == false) ? normalised : nil
        if next == developerUserId { return false }
        developerUserId = next
        syncBox.write(IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: next,
            crossdeckCustomerId: crossdeckCustomerId
        ))
        if let next {
            storage.setString(next, forKey: developerUserIdKey)
        } else {
            storage.remove(developerUserIdKey)
        }
        return true
    }

    /// Set the crossdeckCustomerId. Called from the `/identity/alias`
    /// response handler — the server returns the canonical cdcust_
    /// and we persist it for the lifetime of the install.
    public func setCrossdeckCustomerId(_ id: String?) -> Bool {
        let normalised = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = (normalised?.isEmpty == false) ? normalised : nil
        if next == crossdeckCustomerId { return false }
        crossdeckCustomerId = next
        syncBox.write(IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: developerUserId,
            crossdeckCustomerId: next
        ))
        if let next {
            storage.setString(next, forKey: crossdeckCustomerIdKey)
        } else {
            storage.remove(crossdeckCustomerIdKey)
        }
        return true
    }

    /// Reset clears developerUserId + crossdeckCustomerId AND
    /// regenerates the anonymousId. Used after sign-out so the next
    /// anonymous session is fully unlinked from the prior identified
    /// user.
    public func reset() {
        developerUserId = nil
        crossdeckCustomerId = nil
        storage.remove(developerUserIdKey)
        storage.remove(crossdeckCustomerIdKey)
        let fresh = Identity.makeAnonymousId()
        storage.setString(fresh, forKey: anonymousIdKey)
        anonymousId = fresh
        syncBox.write(IdentitySnapshot(
            anonymousId: fresh,
            developerUserId: nil,
            crossdeckCustomerId: nil
        ))
    }

    /// Snapshot for envelope construction. Returns all three axes so
    /// the caller can include every known identity hint on every
    /// event (server-side dedup needs all three when known).
    public func snapshot() -> IdentitySnapshot {
        return IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: developerUserId,
            crossdeckCustomerId: crossdeckCustomerId
        )
    }

    /// Nonisolated sync snapshot — used by `Crossdeck.isEntitled`
    /// and the error pipeline to read identity without an actor hop.
    public nonisolated func snapshotSync() -> IdentitySnapshot {
        return syncBox.read()
    }

    /// Nonisolated sync setter for developerUserId — guarantees the
    /// update is visible to subsequent sync reads BEFORE this method
    /// returns. Returns true if the id changed, false if it was
    /// identical.
    @discardableResult
    public nonisolated func setDeveloperUserIdSync(_ id: String?) -> Bool {
        let normalised = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = (normalised?.isEmpty == false) ? normalised : nil

        let current = syncBox.read()
        if next == current.developerUserId { return false }

        syncBox.write(IdentitySnapshot(
            anonymousId: current.anonymousId,
            developerUserId: next,
            crossdeckCustomerId: current.crossdeckCustomerId
        ))
        if let next {
            storage.setString(next, forKey: developerUserIdKey)
        } else {
            storage.remove(developerUserIdKey)
        }
        Task { await self.reconcileFromSyncBox() }
        return true
    }

    /// Nonisolated sync setter for crossdeckCustomerId. Same
    /// semantics as `setDeveloperUserIdSync` — sync mirror + storage
    /// written before return; actor state reconciled async.
    @discardableResult
    public nonisolated func setCrossdeckCustomerIdSync(_ id: String?) -> Bool {
        let normalised = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = (normalised?.isEmpty == false) ? normalised : nil

        let current = syncBox.read()
        if next == current.crossdeckCustomerId { return false }

        syncBox.write(IdentitySnapshot(
            anonymousId: current.anonymousId,
            developerUserId: current.developerUserId,
            crossdeckCustomerId: next
        ))
        if let next {
            storage.setString(next, forKey: crossdeckCustomerIdKey)
        } else {
            storage.remove(crossdeckCustomerIdKey)
        }
        Task { await self.reconcileFromSyncBox() }
        return true
    }

    /// Internal helper invoked from sync setters to bring the actor's
    /// own state in line with the sync mirror.
    private func reconcileFromSyncBox() {
        let current = syncBox.read()
        anonymousId = current.anonymousId
        developerUserId = current.developerUserId
        crossdeckCustomerId = current.crossdeckCustomerId
    }

    /// UUIDv4 anonymous id with the canonical `anon_` prefix the
    /// platform-wide regex validates against.
    private static func makeAnonymousId() -> String {
        return "anon_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
