// AppAccountTokenDerivation — bank-grade appAccountToken handling
// for the Crossdeck Apple-rail purchase sync.
//
// Phase 2.1 of bank-grade reconciliation v1.4.0. Pre-v1.4.0 the
// auto-track path stuffed the StoreKit `originalTransactionId`
// (a numeric string) into the wire-level `appAccountToken` field,
// which violates the StoreKit contract — `appAccountToken` is
// defined as a UUID. A numeric string passes the SDK and reaches
// the backend, but any downstream system that interprets it as a
// UUID (analytics joins, Apple's own server-to-server notifications)
// is wrong.
//
// The fix:
//   * Derive a proper UUID from `developerUserId`.
//   * Send `originalTransactionId` in its own dedicated wire field
//     so the backend can still correlate without polluting the
//     UUID slot.
//
// Decision tree:
//   1. If `developerUserId` parses as a valid UUID, use it directly
//      (caller already gave us a UUID — no derivation needed).
//   2. Else if `developerUserId` is non-empty, derive RFC 4122 §4.3
//      UUID v5 from the URL namespace + "crossdeck:<id>" — stable
//      across launches, so resubmitting the same purchase produces
//      the same token (Apple uses this for cross-receipt linkage).
//   3. Else (no developerUserId), omit the field. The backend
//      validator accepts null; never silently sending a wrong UUID
//      is the bank-grade default.

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
