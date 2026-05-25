// Super-properties: a small dictionary of values automatically
// attached to every event the SDK sends.
//
// Mirrors the same surface as the Web/Node/RN SDKs:
//
//   * register(_:)         — set / overwrite a key
//   * registerOnce(_:)     — set IFF the key isn't already present
//   * unregister(_:)       — remove a single key
//   * clear()              — wipe everything
//
// Persisted as a single JSON blob in storage so the values survive
// process restarts (e.g. "appVersion" gets registered once at boot
// and is then on every subsequent event for the lifetime of the
// install). The blob is rewritten in full on every mutation —
// these properties are O(10) items in normal use, so a partial
// patch protocol would be over-engineered.

import Foundation

/// Sync-readable mirror of the super-properties map, lock-protected
/// so `Crossdeck.track` can include super-props in the event payload
/// without an actor hop.
final class SuperPropertiesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(initial: [String: String]) {
        self.values = initial
    }

    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func write(_ next: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        values = next
    }
}

public actor SuperProperties {
    private let storage: Storage
    private let storageKey: String = "super_props"
    private var values: [String: String]
    private let syncBox: SuperPropertiesBox

    public init(storage: Storage) {
        self.storage = storage
        let initial: [String: String]
        if let blob = storage.getString(storageKey),
           let data = blob.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
            initial = parsed
        } else {
            initial = [:]
        }
        self.values = initial
        self.syncBox = SuperPropertiesBox(initial: initial)
    }

    public func register(_ key: String, _ value: String) {
        // Empty keys would land on every wire event as a useless
        // null-key entry — reject at the boundary.
        guard !key.isEmpty else { return }
        values[key] = value
        syncBox.write(values)
        persist()
    }

    /// Only writes if the key isn't already present. Useful for
    /// values like "first_install_version" that must reflect the
    /// version at install time, not the version at every launch.
    public func registerOnce(_ key: String, _ value: String) {
        guard !key.isEmpty else { return }
        guard values[key] == nil else { return }
        values[key] = value
        syncBox.write(values)
        persist()
    }

    public func unregister(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        syncBox.write(values)
        persist()
    }

    public func clear() {
        guard !values.isEmpty else { return }
        values.removeAll()
        syncBox.write(values)
        storage.remove(storageKey)
    }

    public func snapshot() -> [String: String] {
        return values
    }

    /// Nonisolated sync snapshot — used by the track pipeline to
    /// merge super-properties into the event payload without an
    /// actor hop on every track call.
    public nonisolated func snapshotSync() -> [String: String] {
        return syncBox.snapshot()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values),
              let blob = String(data: data, encoding: .utf8) else {
            return
        }
        storage.setString(blob, forKey: storageKey)
    }
}
