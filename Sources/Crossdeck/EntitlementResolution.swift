// EntitlementResolution — the three-state access gate.
//
// Crossdeck's pillar #2 ("a paying customer never doesn't get what they paid
// for") rests on a single rule: ACCESS never waits for ATTRIBUTION. A paid
// Apple subscription is two facts in two places — "is this user entitled right
// now" (Apple answers on-device, cryptographically signed, instantly, offline)
// and "which of your users owns it" (the backend answers, eventually). The
// first must never be gated on the second.
//
// A bare `Bool` can't express that, because the honest answer is sometimes
// "checking" — the device holds a verified active subscription the SDK can't
// yet name (fresh install, never synced online, currently offline). Collapsing
// that into `false` flashes "not Pro" at a paying subscriber. `EntitlementStatus`
// makes the third state explicit so paywalls can show a spinner instead.

import Foundation

/// Three-state result of an entitlement check.
public enum EntitlementStatus: Sendable, Equatable {
    /// Definitely entitled — a backend grant OR a device-verified Apple
    /// receipt backs this key. Honour it.
    case entitled
    /// Definitely not entitled — the SDK checked and nothing grants it. Safe
    /// to show a paywall.
    case notEntitled
    /// Can't say yet. Either the on-device receipt read is still in flight, or
    /// the device holds a verified active subscription the SDK can't map to an
    /// entitlement key because it has never completed an online sync (fresh
    /// install, fully offline). Self-heals on first connectivity. Show
    /// "checking your subscription…" — NEVER a hard paywall.
    case resolving
}

/// Pure resolution logic — no StoreKit, no actors, no I/O — so the gate that
/// pillar #2 rides on is unit-testable on every platform Package.swift builds
/// against. The iOS-gated caller feeds it real StoreKit + cache data; tests
/// feed synthetic data.
///
/// The reconciliation rule, stated once: PROTECT AGAINST BACKEND-ABSENT, YIELD
/// TO BACKEND-PRESENT-AND-DISAGREES.
///   * A device-verified receipt is sacrosanct against an *absent* backend —
///     never revoked just because the network is down (Apple's signature is
///     proof of payment).
///   * The product→key MAP is developer config, not a payment fact — so a
///     reachable backend that re-sources a product's mapping wins. That isn't
///     handled here; it's handled by rebuilding `productMap` last-snapshot-wins
///     from the freshest backend snapshot (see AppleProductMap). This function
///     just consumes whatever the current map says.
enum EntitlementResolution {
    /// Resolve one entitlement `key`.
    ///
    /// - Parameters:
    ///   - backendGrantsKey: the backend entitlement cache (persisted, may be
    ///     offline-hydrated from a prior session) says this key is active. A
    ///     POSITIVE backend fact — honoured first, never revoked on staleness.
    ///   - localActiveProductIds: verified, currently-active Apple product IDs
    ///     from `Transaction.currentEntitlements`. `nil` means the StoreKit
    ///     read has NOT completed yet — distinct from "read, and empty".
    ///   - productMap: productId → entitlement keys, rebuilt last-snapshot-wins
    ///     from the most recent backend snapshot. May be empty before first
    ///     successful sync (the no-map sliver).
    static func resolve(
        key: String,
        backendGrantsKey: Bool,
        localActiveProductIds: Set<String>?,
        productMap: [String: Set<String>]
    ) -> EntitlementStatus {
        // 1. Backend grant wins. Covers cross-device (paid on another device,
        //    the backend projected the entitlement to this one) and the common
        //    warm-cache return. A positive is never revoked on staleness.
        if backendGrantsKey { return .entitled }

        // 2. On-device receipt read still pending. Return `.resolving`, NOT
        //    `.notEntitled`, so a paying subscriber never sees a flash of
        //    "not Pro" on cold launch before StoreKit answers. A free user
        //    sees a brief "checking" that resolves to `.notEntitled` in ms.
        guard let local = localActiveProductIds else { return .resolving }

        // 3. A verified active receipt maps to this key — SACROSANCT. Grants
        //    even offline, even against a backend that is absent or disagrees
        //    by omission. Apple's signature is the proof of payment.
        if local.contains(where: { productMap[$0]?.contains(key) == true }) {
            return .entitled
        }

        // 4. The device HAS a verified active subscription we cannot yet name
        //    (no map entry — never synced online). We know they paid for
        //    SOMETHING; we can't prove it's THIS key. Don't hard-deny —
        //    `.resolving` ("connect once to restore"). Self-heals when the map
        //    fills on first sync. Triggers ONLY on genuine evidence of payment,
        //    so free users (empty local set) fall straight through to step 5.
        if local.contains(where: { productMap[$0] == nil }) {
            return .resolving
        }

        // 5. Read complete, every active receipt is mapped, none backs this
        //    key, and the backend doesn't grant it. Definitively not entitled.
        return .notEntitled
    }
}
