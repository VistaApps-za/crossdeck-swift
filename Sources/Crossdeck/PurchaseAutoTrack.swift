// PurchaseAutoTrack — automatic StoreKit 2 transaction observation.
//
// iOS 15+ StoreKit 2 exposes `Transaction.updates` as an
// AsyncSequence — every purchase, restore, renewal, and refund the
// system signs flows through it. Without an observer, transactions
// queued while the app was killed get re-delivered on next launch
// and the developer has to remember to call syncPurchases() in their
// app's launch path. With this observer, Crossdeck consumes the
// stream automatically and forwards every signed transaction to
// the backend for verification — same code path syncPurchases() uses,
// no contract drift.
//
// Two-track emission:
//   1. The signed JWS payload goes to `/purchases/sync` so the
//      backend can verify with Apple's public key and project the
//      entitlement state.
//   2. A `purchase.completed` / `purchase.refunded` event is also
//      tracked through the normal event pipeline so dashboards
//      see the funnel boundary in real time.
//
// Bank-grade contract (v1.4.0 — Phase 1.2 of bank-grade
// reconciliation):
//   * iOS 15+ only. Older targets skip silently — syncPurchases()
//     remains the manual path.
//   * Opt-in via `CrossdeckOptions(automaticPurchaseTracking: true)`.
//     OFF by default because most apps already call syncPurchases()
//     from their own purchase confirmation flow and don't want
//     duplicate work.
//   * Cancellable: stop() ends the consumer task cleanly.
//   * `transaction.finish()` is called STRICTLY inside the success
//     branch of the backend sync. A 5xx during sync leaves the
//     StoreKit transaction unfinished so Apple's re-delivery
//     mechanism keeps the purchase alive across launches. The
//     in-process [PendingPurchaseQueue] additionally drives
//     same-session backoff retries (max 5 attempts, exp backoff
//     30s/1m/5m/30m/2h) so a transient outage doesn't have to
//     wait for the next cold launch to recover.

import Foundation

#if canImport(StoreKit) && os(iOS)
import StoreKit

@available(iOS 15.0, *)
final class PurchaseAutoTrack: @unchecked Sendable {
    typealias EmitTrack = @Sendable (_ name: String, _ properties: [String: Any]) -> Void

    /// Returns `.success` on 2xx + entitlement-projection complete;
    /// `.failure(CrossdeckError)` carrying the typed envelope on
    /// any non-success. The caller (handle) MUST NOT call
    /// `transaction.finish()` on failure — purchase durability
    /// depends on Apple's re-delivery + the [PendingPurchaseQueue]
    /// retry path.
    typealias SyncBackend = @Sendable (_ jwsRepresentation: String, _ originalTransactionId: String?) async -> Result<Void, CrossdeckError>

    /// Indirection for `transaction.finish()` so unit tests can
    /// observe whether finish() was called without instantiating a
    /// real `StoreKit.Transaction` (which isn't constructible from
    /// outside StoreKit).
    typealias FinishTransaction = @Sendable (Transaction) async -> Void

    private let emitTrack: EmitTrack
    private let syncBackend: SyncBackend
    private let pendingQueue: PendingPurchaseQueue
    private let finishTransaction: FinishTransaction
    private let drainIntervalNanos: UInt64
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    init(
        emitTrack: @escaping EmitTrack,
        syncBackend: @escaping SyncBackend,
        pendingQueue: PendingPurchaseQueue,
        finishTransaction: FinishTransaction? = nil,
        drainIntervalSeconds: TimeInterval = 30
    ) {
        self.emitTrack = emitTrack
        self.syncBackend = syncBackend
        self.pendingQueue = pendingQueue
        self.finishTransaction = finishTransaction ?? { await $0.finish() }
        self.drainIntervalNanos = UInt64(max(1, drainIntervalSeconds) * 1_000_000_000)
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        let emit = emitTrack
        let sync = syncBackend
        let queue = pendingQueue
        let finish = finishTransaction
        task = Task.detached(priority: .utility) {
            // Transaction.updates emits one element per system-signed
            // transaction — purchases, renewals, refunds, family-shared.
            // Loop runs for the app's lifetime; cancel() ends it.
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                // jwsRepresentation lives on VerificationResult (iOS
                // 15+), not the inner Transaction — the JWS includes
                // both header + payload + signature, which is what
                // the backend needs to verify.
                let jws = result.jwsRepresentation
                switch result {
                case .verified(let transaction):
                    await Self.handle(
                        transaction: transaction,
                        jws: jws,
                        emit: emit,
                        sync: sync,
                        queue: queue,
                        finish: finish
                    )
                case .unverified(let transaction, let error):
                    // Surface as a tracked event so the dashboard
                    // shows unverified attempts (fraud detection
                    // signal). DO NOT sync to backend — only verified
                    // transactions cross the trust boundary.
                    emit("purchase.unverified", [
                        "productId": transaction.productID,
                        "verificationError": String(describing: error),
                    ])
                }
            }
        }

        // Periodic retry drain — wakes every `drainIntervalNanos`,
        // pulls due entries, attempts to re-sync each via the
        // matching unfinished Transaction.
        let interval = drainIntervalNanos
        drainTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await Self.drainPendingQueue(
                    queue: queue,
                    sync: sync,
                    finish: finish,
                    emit: emit
                )
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        drainTask?.cancel()
        drainTask = nil
        lock.unlock()
    }

    @available(iOS 15.0, *)
    private static func handle(
        transaction: Transaction,
        jws: String,
        emit: EmitTrack,
        sync: SyncBackend,
        queue: PendingPurchaseQueue,
        finish: FinishTransaction
    ) async {
        let originalId = String(transaction.originalID)

        // 1. Forward signed payload to backend BEFORE emitting the
        //    public event so the backend has the receipt when the
        //    dashboard renders the purchase row.
        let syncResult: Result<Void, CrossdeckError>
        if !jws.isEmpty {
            syncResult = await sync(jws, originalId)
        } else {
            // Empty JWS means the transaction lacked a verifiable
            // representation — emit the funnel event but skip the
            // backend call. Treat as "no sync needed" rather than
            // a failure so we don't queue a sync that has no
            // payload.
            syncResult = .success(())
        }

        // 2. Emit the public funnel event (independent of sync
        //    outcome — the dashboard funnel records the purchase
        //    regardless of backend acknowledgement).
        var props: [String: Any] = [
            "productId": transaction.productID,
            "transactionId": String(transaction.id),
            "originalTransactionId": originalId,
            "purchaseDate": ISO8601DateFormatter().string(from: transaction.purchaseDate),
        ]
        if transaction.revocationDate != nil {
            props["revocationDate"] = ISO8601DateFormatter().string(from: transaction.revocationDate!)
            if let reason = transaction.revocationReason {
                props["revocationReason"] = reason.rawValue
            }
            emit("purchase.refunded", props)
        } else {
            emit("purchase.completed", props)
        }

        // 3. Branch on sync result. Bank-grade contract: .finish()
        //    is called STRICTLY inside the success branch.
        switch syncResult {
        case .success:
            await queue.recordSuccess(originalTransactionId: originalId)
            await finish(transaction)
        case .failure(let err):
            // Persist for retry. DO NOT finish — Apple's
            // Transaction.updates re-delivery + the in-process
            // drain task keep the retry path alive.
            _ = await queue.recordFailure(
                originalTransactionId: originalId,
                jws: jws
            )
            emit("purchase.sync_failed", [
                "rail": "apple",
                "productId": transaction.productID,
                "originalTransactionId": originalId,
                "errorType": err.type.rawValue,
                "errorCode": err.code,
                "statusCode": err.statusCode as Any,
            ])
        }
    }

    /// Drain pass — called periodically by the drain task. For
    /// each due entry, locate the matching Transaction in
    /// `Transaction.unfinished` and retry the sync. On success
    /// finish + clear; on failure re-record (advancing the
    /// backoff); if StoreKit no longer tracks the transaction,
    /// drop the entry (Apple-side reconciliation removed it).
    @available(iOS 15.0, *)
    private static func drainPendingQueue(
        queue: PendingPurchaseQueue,
        sync: SyncBackend,
        finish: FinishTransaction,
        emit: EmitTrack
    ) async {
        let due = await queue.dueEntries()
        guard !due.isEmpty else { return }

        // Index Transaction.unfinished by originalID so we can
        // match without an N×M scan per entry.
        var byOriginalId: [String: Transaction] = [:]
        for await result in Transaction.unfinished {
            if case .verified(let t) = result {
                byOriginalId[String(t.originalID)] = t
            }
        }

        for entry in due {
            guard let transaction = byOriginalId[entry.originalTransactionId] else {
                // StoreKit no longer tracks this transaction —
                // drop the entry so we stop pinging the backend
                // for a receipt Apple has already reconciled.
                await queue.drop(originalTransactionId: entry.originalTransactionId)
                continue
            }
            let result = await sync(entry.jws, entry.originalTransactionId)
            switch result {
            case .success:
                await queue.recordSuccess(originalTransactionId: entry.originalTransactionId)
                await finish(transaction)
            case .failure(let err):
                _ = await queue.recordFailure(
                    originalTransactionId: entry.originalTransactionId,
                    jws: entry.jws
                )
                emit("purchase.sync_retry_failed", [
                    "rail": "apple",
                    "productId": transaction.productID,
                    "originalTransactionId": entry.originalTransactionId,
                    "attempts": entry.attempts,
                    "errorType": err.type.rawValue,
                    "errorCode": err.code,
                    "statusCode": err.statusCode as Any,
                ])
            }
        }
    }
}

/// Pure helper exposed for unit tests — encodes the bank-grade
/// "finish iff sync succeeded" contract in a single boolean. Lives
/// outside the `@available(iOS 15.0, *)` class so it's testable on
/// every platform Package.swift builds against.
internal enum PurchaseFinishDecision {
    /// Returns `true` iff the transaction should be finished now.
    /// Bank-grade invariant: a failed `/purchases/sync` MUST NOT
    /// finish the transaction — purchase durability depends on
    /// StoreKit's re-delivery on the next session.
    static func shouldFinish(syncResult: Result<Void, CrossdeckError>) -> Bool {
        switch syncResult {
        case .success: return true
        case .failure: return false
        }
    }
}
#else
/// Non-iOS / no-StoreKit fallback — keeps the
/// `PurchaseFinishDecision` helper available so unit tests on
/// macOS/Linux can verify the contract.
internal enum PurchaseFinishDecision {
    static func shouldFinish(syncResult: Result<Void, CrossdeckError>) -> Bool {
        switch syncResult {
        case .success: return true
        case .failure: return false
        }
    }
}
#endif
