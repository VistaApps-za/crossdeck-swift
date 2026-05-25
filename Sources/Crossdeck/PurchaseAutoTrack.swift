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
// Bank-grade contract:
//   * iOS 15+ only. Older targets skip silently — syncPurchases()
//     remains the manual path.
//   * Opt-in via `CrossdeckOptions(automaticPurchaseTracking: true)`.
//     OFF by default because most apps already call syncPurchases()
//     from their own purchase confirmation flow and don't want
//     duplicate work.
//   * Cancellable: stop() ends the consumer task cleanly.

import Foundation

#if canImport(StoreKit) && os(iOS)
import StoreKit

@available(iOS 15.0, *)
final class PurchaseAutoTrack: @unchecked Sendable {
    typealias EmitTrack = @Sendable (_ name: String, _ properties: [String: Any]) -> Void
    typealias SyncBackend = @Sendable (_ jwsRepresentation: String, _ originalTransactionId: String?) async -> Void

    private let emitTrack: EmitTrack
    private let syncBackend: SyncBackend
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(emitTrack: @escaping EmitTrack, syncBackend: @escaping SyncBackend) {
        self.emitTrack = emitTrack
        self.syncBackend = syncBackend
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        let emit = emitTrack
        let sync = syncBackend
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
                    await Self.handle(transaction: transaction, jws: jws, emit: emit, sync: sync)
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
        lock.unlock()
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    @available(iOS 15.0, *)
    private static func handle(
        transaction: Transaction,
        jws: String,
        emit: EmitTrack,
        sync: SyncBackend
    ) async {
        // The signed JWS goes to the backend for cryptographic
        // verification + entitlement projection. We do this BEFORE
        // emitting the public event so the backend has the receipt
        // when the dashboard renders the purchase row.
        if !jws.isEmpty {
            await sync(jws, String(transaction.originalID))
        }

        // Emit a public funnel event.
        var props: [String: Any] = [
            "productId": transaction.productID,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID),
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

        // Mark the transaction finished so iOS stops re-delivering
        // it on every launch. This is a StoreKit contract — without
        // .finish() the queue keeps the transaction pending forever.
        await transaction.finish()
    }
}
#endif
