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
    /// Per-install Apple-rail purchase identity. Minted lazily by
    /// `appAccountTokenForCurrentIdentity()` on first purchase, persisted
    /// across launches, **wiped on `reset()`**. See
    /// `AppAccountTokenDerivation.swift` and the design rationale on
    /// `Identity.ensureAppAccountTokenSync()` for why this lifecycle is
    /// what makes Shape 2 impossible-by-construction rather than merely
    /// detectable.
    public let appAccountToken: String?

    public init(
        anonymousId: String,
        developerUserId: String?,
        crossdeckCustomerId: String?,
        appAccountToken: String? = nil
    ) {
        self.anonymousId = anonymousId
        self.developerUserId = developerUserId
        self.crossdeckCustomerId = crossdeckCustomerId
        self.appAccountToken = appAccountToken
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
        crossdeckCustomerId: String?,
        appAccountToken: String? = nil
    ) {
        self.snapshot = IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: developerUserId,
            crossdeckCustomerId: crossdeckCustomerId,
            appAccountToken: appAccountToken
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
    /// Apple-rail purchase identity. UUID string, lazy-minted by
    /// `ensureAppAccountTokenSync()`, persisted across launches, **wiped
    /// on `reset()`** — see the design rationale on that method for the
    /// uniqueness-per-entity property that makes wipe-on-reset
    /// load-bearing rather than aesthetic.
    private let appAccountTokenKey: String = "apple_app_account_token"

    public private(set) var anonymousId: String
    public private(set) var developerUserId: String?
    public private(set) var crossdeckCustomerId: String?
    public private(set) var appAccountToken: String?

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
        // Lazy load — never mint here. The token is only minted on the
        // first call to `ensureAppAccountTokenSync()` so SDKs that never
        // touch Apple-rail purchases don't carry an unused identifier
        // in their persisted state.
        let initialToken = storage.getString(appAccountTokenKey).flatMap { $0.isEmpty ? nil : $0 }
        self.appAccountToken = initialToken
        self.syncBox = IdentityBox(
            anonymousId: initialAnon,
            developerUserId: initialDev,
            crossdeckCustomerId: initialCdcust,
            appAccountToken: initialToken
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
            crossdeckCustomerId: crossdeckCustomerId,
            appAccountToken: appAccountToken
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
            crossdeckCustomerId: next,
            appAccountToken: appAccountToken
        ))
        if let next {
            storage.setString(next, forKey: crossdeckCustomerIdKey)
        } else {
            storage.remove(crossdeckCustomerIdKey)
        }
        return true
    }

    /// Reset clears developerUserId + crossdeckCustomerId, regenerates
    /// the anonymousId, AND wipes the Apple-rail `appAccountToken`.
    /// Used after sign-out so the next anonymous session is fully
    /// unlinked from the prior identified user.
    ///
    /// # Why `appAccountToken` wipes
    ///
    /// The wipe is the load-bearing property that makes Shape 2
    /// (identity-key mismatch) impossible-by-construction on the
    /// Apple rail. It is NOT a cosmetic cleanup — surviving the
    /// wipe re-introduces the bug through a different mechanism:
    ///
    ///   * appAccountToken is permanent in Apple's transaction record.
    ///     Once a purchase commits with token T, the renewal chain
    ///     emits T forever — independent of anything the client does.
    ///   * Server-side, T → customer is single-valued at any instant.
    ///   * If the helper handed T to one user, the binding is theirs
    ///     for the life of that subscription chain.
    ///
    /// If `reset()` did not wipe the token, the next user on the
    /// same device would receive the prior user's T. Their purchase
    /// would arrive at the server carrying T, which is already
    /// bound to the prior user. The single-valued mapping forces
    /// one of the two transactions to misattribute — silent cross-
    /// customer purchase leakage. The existing identity-resolution
    /// machinery (merge-customers, alias chain) cannot fix this:
    /// it unifies many identifiers believed to belong to one
    /// entity, and Alice + Bob are two entities. Feeding their
    /// shared T into merge would instruct the server to merge two
    /// strangers, not split T across them. Token uniqueness-per-
    /// entity is the property that makes server-side join correct.
    ///
    /// Wiping the client's copy does NOT impair resolution of any
    /// existing T — the binding lives on the server, Apple's copy
    /// of T on the transaction is immutable, and the existing
    /// purchase's renewals still resolve to the prior user via the
    /// recorded server-side binding. The local token is only ever
    /// needed to stamp NEW purchases. So the principle: `reset()`
    /// is "the purchasing entity may be changing" — the boundary at
    /// which a new entity should get a new token. Token lifetime
    /// tracks purchasing-entity lifetime. Within one user's arc
    /// (anon → login → SSO) no reset fires, T stays stable, genuine
    /// same-entity merges resolve via anonymousId as they already do.
    public func reset() {
        developerUserId = nil
        crossdeckCustomerId = nil
        appAccountToken = nil
        storage.remove(developerUserIdKey)
        storage.remove(crossdeckCustomerIdKey)
        storage.remove(appAccountTokenKey)
        let fresh = Identity.makeAnonymousId()
        storage.setString(fresh, forKey: anonymousIdKey)
        anonymousId = fresh
        syncBox.write(IdentitySnapshot(
            anonymousId: fresh,
            developerUserId: nil,
            crossdeckCustomerId: nil,
            appAccountToken: nil
        ))
    }

    /// Lazily mint + return the per-install Apple-rail
    /// `appAccountToken`. First call generates a fresh `UUID()`,
    /// persists it, and writes it to the sync mirror. Subsequent
    /// calls return the same value — independent of `identify()`
    /// state, login state, anything. `reset()` (sign-out) wipes the
    /// token; the next call mints a fresh one.
    ///
    /// See the design rationale on `reset()` for why this lifecycle
    /// closes Shape 2. The short version: appAccountToken is
    /// permanent in Apple's record, server-side resolution is
    /// single-valued, so the token must be unique per purchasing
    /// entity for the join to be correct.
    ///
    /// Marked `nonisolated` so the purchase-path (StoreKit
    /// `Transaction.updates` listener + manual `syncPurchases`)
    /// can call it from any context without an actor hop. Writes
    /// land in the sync mirror first; the actor's own state
    /// reconciles on the next mutation. Same pattern as
    /// `setDeveloperUserIdSync`.
    @discardableResult
    public nonisolated func ensureAppAccountTokenSync() -> String {
        let current = syncBox.read()
        if let existing = current.appAccountToken, !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        syncBox.write(IdentitySnapshot(
            anonymousId: current.anonymousId,
            developerUserId: current.developerUserId,
            crossdeckCustomerId: current.crossdeckCustomerId,
            appAccountToken: minted
        ))
        storage.setString(minted, forKey: appAccountTokenKey)
        Task { await self.reconcileFromSyncBox() }
        return minted
    }

    /// Sync read of the persisted token WITHOUT minting. Returns
    /// `nil` when no token has been minted yet. Used by `identify()`
    /// to attach the token to the alias request only if a prior
    /// purchase flow already minted one — `identify()` itself never
    /// triggers minting.
    public nonisolated func appAccountTokenSync() -> String? {
        return syncBox.read().appAccountToken
    }

    /// Snapshot for envelope construction. Returns all four axes
    /// (anonymousId, developerUserId, crossdeckCustomerId,
    /// appAccountToken) so the caller can include every known
    /// identity hint on every event (server-side dedup needs them
    /// when known). The token is intentionally absent on most
    /// snapshots because most installs never touch Apple-rail
    /// purchases — `nil` is the default, present only after the
    /// purchase path mints one.
    public func snapshot() -> IdentitySnapshot {
        return IdentitySnapshot(
            anonymousId: anonymousId,
            developerUserId: developerUserId,
            crossdeckCustomerId: crossdeckCustomerId,
            appAccountToken: appAccountToken
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
            crossdeckCustomerId: current.crossdeckCustomerId,
            appAccountToken: current.appAccountToken
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
            crossdeckCustomerId: next,
            appAccountToken: current.appAccountToken
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
        appAccountToken = current.appAccountToken
    }

    /// UUIDv4 anonymous id with the canonical `anon_` prefix the
    /// platform-wide regex validates against.
    private static func makeAnonymousId() -> String {
        return "anon_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
