// Deterministic Idempotency-Key derivation for /purchases/sync.
//
// Phase 2.2.c of bank-grade reconciliation v1.4.0. Mirrors
// `sdks/web/src/idempotency-key.ts` and `sdks/node/src/idempotency-key.ts`
// byte-identically — the same input (rail + JWS / purchaseToken)
// produces the same UUID-shaped key across every Crossdeck SDK,
// so the backend's idempotency cache short-circuits regardless of
// which client retried.
//
// Algorithm:
//   1. Extract the rail-stable identifier from the request (Apple
//      JWS string, Google purchaseToken).
//   2. SHA-256 of `crossdeck:purchases/sync:<rail>:<identifier>`
//      — rail namespacing prevents cross-rail collisions on bodies
//      that happen to share bytes.
//   3. Format the first 32 hex chars of the digest as a UUID
//      shape (8-4-4-4-12). The backend treats the key as opaque
//      so RFC 4122 version/variant bits are unnecessary —
//      determinism is what matters.
//
// Pinned cross-SDK oracle: deriveForPurchase("apple", "eyJ.jws.sig",
// nil) MUST equal "a66b1640-efaf-bb4d-1261-6650033bf111" on every
// SDK. A regression there is a wire-protocol break.

import Foundation
import CryptoKit

internal enum IdempotencyKey {
    /// Format any hex string as 8-4-4-4-12 UUID shape using its
    /// first 32 chars. Public so callers / tests can use the same
    /// formatter the derivation does.
    static func formatAsUuid(hex: String) -> String {
        let chars = Array(hex)
        precondition(chars.count >= 32, "formatAsUuid requires at least 32 hex chars")
        let part1 = String(chars[0..<8])
        let part2 = String(chars[8..<12])
        let part3 = String(chars[12..<16])
        let part4 = String(chars[16..<20])
        let part5 = String(chars[20..<32])
        return "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
    }

    /// SHA-256 of `input` as a 64-char lowercase hex string.
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive the deterministic Idempotency-Key for a purchase
    /// sync request. Returns `nil` when no rail-stable identifier
    /// is available — caller MUST choose between sending no
    /// idempotency header at all OR raising a typed error, never
    /// silently mint a random key (defeats the contract).
    static func deriveForPurchase(
        rail: String,
        signedTransactionInfo: String? = nil,
        purchaseToken: String? = nil
    ) -> String? {
        let identifier: String
        switch rail {
        case "apple":
            identifier = signedTransactionInfo ?? ""
        case "google":
            identifier = purchaseToken ?? ""
        default:
            identifier = ""
        }
        guard !identifier.isEmpty else { return nil }
        let namespaced = "crossdeck:purchases/sync:\(rail):\(identifier)"
        return formatAsUuid(hex: sha256Hex(namespaced))
    }
}
