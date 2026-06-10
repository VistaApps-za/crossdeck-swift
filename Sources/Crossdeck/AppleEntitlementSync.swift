// AppleEntitlementSync — one-shot sweep of Transaction.currentEntitlements.
//
// PurchaseAutoTrack watches `Transaction.updates`: every NEW purchase,
// renewal, refund the system signs AFTER the listener starts. It does NOT
// re-emit a subscription bought BEFORE this build shipped that hasn't changed
// since — so an existing subscriber who installs the Crossdeck-enabled build
// never links to their developerUserId until their next renewal (up to a full
// billing cycle away).
//
// `Transaction.currentEntitlements` is the missing half: the full set of
// currently-active entitlements on THIS device, right now, historical ones
// included. Sweeping it once per session forwards each verified
// transaction's signed JWS to the SAME `/purchases/sync` endpoint with the
// install-stable appAccountToken. That is how the existing base self-heals
// the first time each subscriber opens the migrated build — no backend
// migration script, no "Restore Purchases" tap.
//
// Identity is NOT required. For an identified install the server binds
// `originalTransactionId → developerUserId`. For an anonymous install (an
// app that never calls `identify()`) the server attributes the subscription
// to the install itself via the appAccountToken, then re-attributes it to
// the user automatically on the first `identify()` that carries the token —
// so an anonymous-only app's revenue is visible on the dashboard from day
// one, and an app that adds auth later loses nothing.
//
// ATTRIBUTION, not ACCESS. This sweep only puts an owner label on a paid
// subscription. A returning subscriber's ACCESS rides on their device's
// signed receipt independently (Phase 3 / `isEntitled`), never on this sweep
// finishing — so the sweep is deliberately:
//   * SILENT — emits no per-sub `purchase.completed` funnel events (those
//     would double-count N historical subscriptions on every launch); just
//     one summary event so the dashboard can see the relink happening.
//   * BEST-EFFORT + IDEMPOTENT — the backend `/purchases/sync` derives a
//     deterministic key from the JWS, so a missed, repeated, or interrupted
//     sweep converges to the same result with nothing double-counted.

import Foundation

#if canImport(StoreKit) && os(iOS)
import StoreKit

@available(iOS 15.0, *)
final class AppleEntitlementSync: @unchecked Sendable {
    typealias SyncBackend = @Sendable (_ jwsRepresentation: String, _ originalTransactionId: String?) async -> Result<Void, CrossdeckError>
    typealias EmitTrack = @Sendable (_ name: String, _ properties: [String: Any]) -> Void

    private let syncBackend: SyncBackend
    private let emitTrack: EmitTrack
    private let lock = NSLock()
    // Per-session dedupe. A sweep is DISCOVERY (and, when identified,
    // attribution) — it only needs to run once per identity-state per
    // process: `currentEntitlements` is the same set until a new purchase
    // lands (which `Transaction.updates` already covers). The dedupe key is
    // the developerUserId when identified, else the stable anonymousId, so:
    // a sign-out → different sign-in re-sweeps, an anonymous→identified
    // transition re-sweeps once, while a repeated `identify()` with the SAME
    // id (common — auth listeners re-fire on every foreground) does not.
    private var sweptForKey: String?
    private var inFlight = false
    private var task: Task<Void, Never>?

    init(syncBackend: @escaping SyncBackend, emitTrack: @escaping EmitTrack) {
        self.syncBackend = syncBackend
        self.emitTrack = emitTrack
    }

    /// Sweep `Transaction.currentEntitlements` once for `dedupeKey` (the
    /// developerUserId when identified, else the stable anonymousId). Cheap
    /// no-op if already swept for this key this session or a sweep is in
    /// flight. Never throws; never blocks the caller (spawns a detached task).
    ///
    /// No identity is required to run: each verified transaction is forwarded
    /// with the install-stable appAccountToken, so an anonymous install's
    /// existing subscribers reach the backend on first launch (the server
    /// attributes them to the install, then re-attributes to the user on the
    /// first `identify()`). The dedupeKey only governs how often the sweep
    /// re-runs within a process.
    func sweep(dedupeKey: String) {
        guard !dedupeKey.isEmpty else { return }
        lock.lock()
        if inFlight || sweptForKey == dedupeKey {
            lock.unlock()
            return
        }
        inFlight = true
        let sync = syncBackend
        let emit = emitTrack
        let started = Task.detached(priority: .utility) { [weak self] in
            await Self.run(sync: sync, emit: emit)
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            self.sweptForKey = dedupeKey
            self.task = nil
            self.lock.unlock()
        }
        task = started
        lock.unlock()
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        inFlight = false
        lock.unlock()
    }

    private static func run(sync: SyncBackend, emit: EmitTrack) async {
        var attempted = 0
        var linked = 0
        var skippedFamilyShared = 0
        // `currentEntitlements` yields ONLY currently-valid entitlements
        // (StoreKit filters expired + revoked), so every verified element is a
        // live subscription worth binding to this user.
        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { break }
            guard case .verified(let transaction) = result else { continue }

            // Phase 5 — matching discipline: NEVER attribute a family-shared
            // subscription. Its `originalTransactionId` belongs to the family
            // ORGANIZER, not this user; binding it here (with this user's
            // appAccountToken attached by the sync closure) would hand the
            // organizer's subscription to a family member — a wrong-merge, the
            // one thing pillar #1 forbids. ACCESS is unaffected: the family
            // member is still entitled locally (AppleLocalEntitlements includes
            // family-shared for the gate); only the owner-label binding is
            // withheld. The organizer attributes it on their OWN device, where
            // the transaction is `.purchased`.
            if transaction.ownershipType == .familyShared {
                skippedFamilyShared += 1
                continue
            }

            let jws = result.jwsRepresentation
            guard !jws.isEmpty else { continue }
            attempted += 1
            let outcome = await sync(jws, String(transaction.originalID))
            if case .success = outcome { linked += 1 }
        }
        // One summary event (NOT one-per-sub) so the dashboard sees the relink
        // without N historical `purchase.completed` rows on every launch.
        if attempted > 0 || skippedFamilyShared > 0 {
            emit("apple.entitlements_resynced", [
                "attempted": attempted,
                "linked": linked,
                "skipped_family_shared": skippedFamilyShared,
                "rail": "apple",
            ])
        }
    }
}
#endif
