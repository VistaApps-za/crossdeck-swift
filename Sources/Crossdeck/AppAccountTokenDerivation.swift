// AppAccountTokenDerivation — DEPRECATED post-v1.4.x.
//
// Do NOT call from new code. Use
// `Crossdeck.appAccountTokenForCurrentIdentity()` instead.
//
// =========================================================
// Why this file is deprecated
// =========================================================
//
// The function below derives `appAccountToken` deterministically
// from `developerUserId`. That looks elegant: same id → same
// token, no persistence required. The property it actually has —
// and the bug it shipped to production at v1.4.0 — is that the
// token is a function of an identifier that is MUTABLE across a
// user's life.
//
// The failure walks itself:
//
//   1. User is anonymous; auto-track path derives token T1 from
//      whatever pseudonymous handle is current.
//   2. Purchase commits. Apple stores T1 PERMANENTLY in its
//      transaction record. T1 appears on every renewal of that
//      chain until the subscription ends.
//   3. User signs in. developerUserId changes to their real ID.
//      The helper now derives T2 ≠ T1.
//   4. The original purchase's renewals continue to arrive at the
//      Crossdeck backend carrying T1. T1 is not bound to anyone
//      in the SDK's view; the SDK cannot reproduce T1 anymore.
//   5. The user's identified purchases are now keyed by T2 in
//      the SDK's model but T1 in Apple's. The server-side join
//      breaks silently; the subscription orphans under the wrong
//      customer or under no customer at all.
//
// Anon-purchase-then-login, account merges, and email-to-SSO
// upgrades are the median paid-user path, not edge cases. Shape 2
// (identity-key mismatch) shipped to production through this
// derivation. Bug count grew linearly with auto-tracked purchases.
//
// =========================================================
// The replacement
// =========================================================
//
// `Crossdeck.appAccountTokenForCurrentIdentity()` mints a fresh
// random UUID on first call, persists it under the storage key
// `crossdeck.apple_app_account_token`, and returns the same value
// forever — independent of any identity mutation. The server
// learns the binding via `identify()`'s alias request, which now
// carries `appAccountToken` alongside `userId` + `anonymousId`.
// Webhook arrives with that token later → server resolves via
// the recorded binding, not via a derivation guess.
//
// `reset()` (sign-out) wipes the token; the next user on the
// same device mints a fresh one. See `Identity.reset()` for why
// wipe-on-reset is the load-bearing property that makes the
// uniqueness-per-entity invariant hold across multi-user devices.
//
// =========================================================
// What stays
// =========================================================
//
// The function below remains in the module to keep the pinned
// cross-SDK oracle (`a66b1640-efaf-bb4d-1261-6650033bf111` for
// `deriveForPurchase("apple", "eyJ.jws.sig", nil)`) asserting as
// a back-compat verification of the wire format itself — it is
// no longer called from the auto-track or syncPurchases paths
// inside the SDK. The internal access level means no third-party
// consumer can call it directly.

import Foundation
import CryptoKit

internal enum AppAccountTokenDerivation {
    /// RFC 4122 Appendix C URL namespace. Used as the namespace for
    /// the UUID v5 derivation when `developerUserId` is not itself
    /// a UUID — the resulting token is stable across launches for
    /// the same developer-supplied identifier.
    static let crossdeckNamespace = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!

    /// Derive the appAccountToken to send on the wire. Returns
    /// `nil` when no identity is available — preferred to sending
    /// a wrong UUID. Returns the canonical lowercase 8-4-4-4-12
    /// hex form when present (matches the format the backend
    /// validator expects post-v1.4.0).
    static func derive(developerUserId: String?) -> String? {
        guard let id = developerUserId, !id.isEmpty else { return nil }
        if let direct = UUID(uuidString: id) {
            return direct.uuidString.lowercased()
        }
        let v5 = uuidV5(namespace: crossdeckNamespace, name: "crossdeck:" + id)
        return v5.uuidString.lowercased()
    }

    /// RFC 4122 §4.3 UUID v5: SHA-1(namespace || name), then set
    /// the version + variant bits. SHA-1 is cryptographically weak,
    /// but UUID v5 doesn't rely on collision resistance for its
    /// purpose (deterministic namespacing) — CryptoKit's
    /// `Insecure.SHA1` is the right primitive here.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        let nsBytes = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        let nameBytes = Data(name.utf8)
        var hasher = Insecure.SHA1()
        hasher.update(data: nsBytes)
        hasher.update(data: nameBytes)
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 10xx
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
