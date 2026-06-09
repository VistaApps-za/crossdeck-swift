// AppleProductMap — the learned productId → entitlement-key reverse map.
//
// To resolve a verified `Transaction.currentEntitlements` receipt to an
// entitlement key on-device (EntitlementResolution step 3), the SDK needs to
// know which entitlement a StoreKit product backs. That mapping is developer
// config and lives in the backend catalog — but every backend entitlement
// snapshot already carries it: `PublicEntitlement.source.productId → .key`. So
// the SDK LEARNS the map from any snapshot it receives and persists it, making
// it available offline on the next launch (even before this session syncs).
//
// LAST-SNAPSHOT-WINS: each update REPLACES the map (never merges across
// snapshots), so a product→key pairing retired in the catalog can't linger
// on-device. The map is app-GLOBAL (a product maps to the same entitlement for
// every user), so it survives identify()/reset() and user switches.

import Foundation

final class AppleProductMap: @unchecked Sendable {
    private static let storageKey = "crossdeck:apple_product_entitlement_map"
    private let storage: Storage
    private let lock = NSLock()
    private var map: [String: Set<String>] = [:]

    init(storage: Storage) {
        self.storage = storage
        load()
    }

    /// Sync read for the resolution hot path. Lock-protected mirror; never
    /// crosses an actor boundary.
    func snapshot() -> [String: Set<String>] {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    /// Rebuild from a full backend entitlement snapshot. Only Apple-rail
    /// sources contribute (those are the ones StoreKit can verify on-device).
    /// Last-snapshot-wins: a product dropped from the latest snapshot drops
    /// from the map.
    func update(from entitlements: [PublicEntitlement]) {
        var next: [String: Set<String>] = [:]
        for e in entitlements {
            guard e.source.rail == .apple else { continue }
            let pid = e.source.productId
            guard !pid.isEmpty else { continue }
            next[pid, default: []].insert(e.key)
        }
        // Don't clobber a populated map with an empty one. The map is global
        // app config; a single user's Apple-less snapshot (e.g. a Stripe-only
        // customer, or a request that happened to carry no Apple sources)
        // must not erase a previously-learned Apple mapping. Last-snapshot-wins
        // applies to snapshots that actually carry Apple mappings.
        guard !next.isEmpty else { return }
        lock.lock()
        let changed = next != map
        map = next
        lock.unlock()
        if changed { persist(next) }
    }

    private func load() {
        guard let raw = storage.getString(Self.storageKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        var m: [String: Set<String>] = [:]
        for (k, v) in decoded { m[k] = Set(v) }
        lock.lock(); map = m; lock.unlock()
    }

    private func persist(_ m: [String: Set<String>]) {
        let encodable = m.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(encodable),
              let str = String(data: data, encoding: .utf8) else { return }
        storage.setString(str, forKey: Self.storageKey)
    }
}
