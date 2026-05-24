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

public actor SuperProperties {
    private let storage: Storage
    private let storageKey: String = "super.props"
    private var values: [String: String]

    public init(storage: Storage) {
        self.storage = storage
        if let blob = storage.getString(storageKey),
           let data = blob.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
            self.values = parsed
        } else {
            self.values = [:]
        }
    }

    public func register(_ key: String, _ value: String) {
        values[key] = value
        persist()
    }

    /// Only writes if the key isn't already present. Useful for
    /// values like "first_install_version" that must reflect the
    /// version at install time, not the version at every launch.
    public func registerOnce(_ key: String, _ value: String) {
        guard values[key] == nil else { return }
        values[key] = value
        persist()
    }

    public func unregister(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        persist()
    }

    public func clear() {
        guard !values.isEmpty else { return }
        values.removeAll()
        storage.remove(storageKey)
    }

    public func snapshot() -> [String: String] {
        return values
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values),
              let blob = String(data: data, encoding: .utf8) else {
            return
        }
        storage.setString(blob, forKey: storageKey)
    }
}
