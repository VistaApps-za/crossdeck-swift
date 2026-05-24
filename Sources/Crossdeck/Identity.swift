// Identity actor.
//
// Owns the lifecycle of anonymousId + customerId across process
// restarts. Two invariants matter:
//
//   * anonymousId persists from first launch until the SDK is
//     `.reset()`. It is never regenerated except by reset. Restoring
//     it across launches is what makes pre-identify analytics roll
//     up into the same person after identify is eventually called.
//
//   * customerId, when present, takes priority over anonymousId in
//     event envelopes. Setting customerId via `identify(...)` does
//     NOT clear anonymousId — both are kept so server-side merge
//     can attribute pre-identify events to the now-known person.
//
// Actor-isolated. All access goes through async methods, so any
// race between a pending event flush reading the current customer
// id and an `identify(...)` call updating it is serialised by the
// actor.

import Foundation

public actor Identity {
    private let storage: Storage
    private let anonymousIdKey: String = "id.anon"
    private let customerIdKey: String = "id.customer"

    public private(set) var anonymousId: String
    public private(set) var customerId: String?

    /// Designated initialiser. Reads existing identity from storage;
    /// if no anonymousId is stored, generates one and persists it
    /// before returning. This means every Identity instance starts
    /// life with a non-nil anonymousId — callers never need to
    /// handle "what if there's no id yet" branches.
    public init(storage: Storage) {
        self.storage = storage
        let storedAnon = storage.getString(anonymousIdKey)
        if let storedAnon, !storedAnon.isEmpty {
            self.anonymousId = storedAnon
        } else {
            let fresh = Identity.makeAnonymousId()
            storage.setString(fresh, forKey: anonymousIdKey)
            self.anonymousId = fresh
        }
        self.customerId = storage.getString(customerIdKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Set the customerId. Idempotent — calling with the same id
    /// twice is a no-op (no storage write, no debug signal).
    public func setCustomerId(_ id: String?) -> Bool {
        let normalised = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = (normalised?.isEmpty == false) ? normalised : nil
        if next == customerId { return false }
        customerId = next
        if let next {
            storage.setString(next, forKey: customerIdKey)
        } else {
            storage.remove(customerIdKey)
        }
        return true
    }

    /// Reset clears the customerId AND regenerates the anonymousId.
    /// Used after sign-out so the next anonymous session is not
    /// linked to the prior identified user.
    public func reset() {
        customerId = nil
        storage.remove(customerIdKey)
        let fresh = Identity.makeAnonymousId()
        storage.setString(fresh, forKey: anonymousIdKey)
        anonymousId = fresh
    }

    /// Snapshot for envelope construction. Returns both ids so the
    /// caller can include anonymousId on every event (server-side
    /// merge needs it) and customerId when known.
    public func snapshot() -> (anonymousId: String, customerId: String?) {
        return (anonymousId, customerId)
    }

    /// UUIDv4 with the Crossdeck-anonymous prefix the platform uses
    /// to distinguish a generated anonymous id from a customer-
    /// provided one. Pattern shared across all SDKs.
    private static func makeAnonymousId() -> String {
        return "cdanon_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
