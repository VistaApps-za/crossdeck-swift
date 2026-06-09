// AppleLocalEntitlements — the on-device access source of truth.
//
// Pillar #2's airtight half: a returning subscriber is entitled by their own
// device's signed receipt the instant they open the app — offline, before any
// backend round-trip, before attribution. This component reads
// `Transaction.currentEntitlements` (the set of currently-valid, system-signed
// entitlements on THIS device — StoreKit already filters expired + revoked)
// and keeps a lock-protected mirror of the verified active product IDs for the
// synchronous `isEntitled` / `entitlementStatus` gate.
//
// It re-reads on every `Transaction.updates` element so the mirror stays fresh
// after a purchase, renewal, or refund mid-session. This is a SEPARATE,
// always-on observer from the opt-in PurchaseAutoTrack: access is not opt-in.
// It does NO networking and emits NO events — it only answers "what does this
// device's receipt say, right now."
//
// `nil` from `snapshot()` means the first read has not completed yet (distinct
// from "read, and empty") — the resolver maps that to `.resolving` so a payer
// never sees a flash of "not Pro" during the boot read.

import Foundation

#if canImport(StoreKit) && os(iOS)
import StoreKit

@available(iOS 15.0, *)
final class AppleLocalEntitlements: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var activeProductIds: Set<String> = []
    private var observerTask: Task<Void, Never>?

    /// Begin reading. Scans `currentEntitlements` once immediately, then keeps
    /// the mirror fresh by re-scanning whenever StoreKit signs a new
    /// transaction. Idempotent — a second call is a no-op.
    func start() {
        lock.lock()
        guard observerTask == nil else { lock.unlock(); return }
        observerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.refresh()
            for await _ in Transaction.updates {
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        observerTask?.cancel()
        observerTask = nil
        lock.unlock()
    }

    /// The verified, currently-active product IDs on this device. `nil` until
    /// the first scan completes.
    func snapshot() -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return loaded ? activeProductIds : nil
    }

    private func refresh() async {
        var ids: Set<String> = []
        // currentEntitlements yields ONLY currently-valid entitlements — every
        // VERIFIED element is a live receipt. Unverified results are skipped:
        // an unsigned/spoofed claim grants nothing.
        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { break }
            if case .verified(let transaction) = result {
                ids.insert(transaction.productID)
            }
        }
        lock.lock()
        activeProductIds = ids
        loaded = true
        lock.unlock()
    }
}
#endif
