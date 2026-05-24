// Persistent KV storage abstraction.
//
// The SDK persists two classes of state across process restarts:
//
//   * Identity (anonymousId, optional customerId, super-properties)
//   * Entitlement cache (single JSON blob keyed by customerId)
//   * Queued events (durability when offline)
//
// On Apple platforms `UserDefaults` is the right default — it's
// available from the watch through the Mac, survives app restarts,
// and (importantly) is on-device-only so we never accidentally
// sync customer identifiers to iCloud.
//
// We hide that behind a `Storage` protocol because some hosts
// (App Extensions with no shared container, tests) need a memory-
// only fallback, and consumers building inside enterprise MDM
// environments may want to inject Keychain or a sandboxed
// container. The protocol is intentionally tiny — get/set/remove —
// to make custom implementations a 5-minute conformance.

import Foundation

public protocol Storage: Sendable {
    func getString(_ key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func remove(_ key: String)
}

/// UserDefaults-backed storage with a Crossdeck-scoped key prefix
/// so we never collide with the host app's own keys. Default
/// suite is `.standard`; pass a custom suite name to scope writes
/// to an App Group (useful for sharing identity across an app +
/// its widget / share extension).
public final class UserDefaultsStorage: Storage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(suiteName: String? = nil, prefix: String = "crossdeck.") {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        self.prefix = prefix
    }

    private func k(_ key: String) -> String { prefix + key }

    public func getString(_ key: String) -> String? {
        defaults.string(forKey: k(key))
    }

    public func setString(_ value: String, forKey key: String) {
        defaults.set(value, forKey: k(key))
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: k(key))
    }
}

/// In-memory fallback. Used in tests, in restricted execution
/// environments (some App Extensions), and as the explicit choice
/// for consumers who do not want any cross-launch persistence. NOT
/// safe across concurrent writers without external synchronisation —
/// the SDK only mutates from inside actors, so production usage is
/// fine, but tests that share an instance across threads should wrap
/// it in their own lock.
public final class MemoryStorage: Storage, @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func getString(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func setString(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }
}
