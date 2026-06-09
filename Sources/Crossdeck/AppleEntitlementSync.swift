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
// included. Sweeping it once per identified session forwards each verified
// transaction's signed JWS to the SAME `/purchases/sync` endpoint, binding
// `originalTransactionId → developerUserId`. That is how the existing base
// self-heals the first time each subscriber opens the migrated build — no
// backend migration script, no "Restore Purchases" tap.
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
    // Per-session dedupe. A sweep is attribution — it only needs to run once
    // per identity per process: `currentEntitlements` is the same set until a
    // new purchase lands (which `Transaction.updates` already covers). Keying
    // on the developerUserId we last swept for means a sign-out → different
    // sign-in re-sweeps, while a repeated `identify()` with the SAME id
    // (common — auth listeners re-fire on every foreground) does not.
    private var sweptForUserId: String?
    private var inFlight = false
    private var task: Task<Void, Never>?

    init(syncBackend: @escaping SyncBackend, emitTrack: @escaping EmitTrack) {
        self.syncBackend = syncBackend
        self.emitTrack = emitTrack
    }

    /// Sweep `Transaction.currentEntitlements` once for `userId`. Cheap no-op
    /// if already swept for this user this session or a sweep is in flight.
    /// Never throws; never blocks the caller (spawns a detached task).
    func sweep(forUserId userId: String) {
        guard !userId.isEmpty else { return }
        lock.lock()
        if inFlight || sweptForUserId == userId {
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
            self.sweptForUserId = userId
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
        // `currentEntitlements` yields ONLY currently-valid entitlements
        // (StoreKit filters expired + revoked), so every verified element is a
        // live subscription worth binding to this user.
        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { break }
            guard case .verified(let transaction) = result else { continue }
            let jws = result.jwsRepresentation
            guard !jws.isEmpty else { continue }
            attempted += 1
            let outcome = await sync(jws, String(transaction.originalID))
            if case .success = outcome { linked += 1 }
        }
        // One summary event (NOT one-per-sub) so the dashboard sees the relink
        // without N historical `purchase.completed` rows on every launch.
        if attempted > 0 {
            emit("apple.entitlements_resynced", [
                "attempted": attempted,
                "linked": linked,
                "rail": "apple",
            ])
        }
    }
}
#endif
