// Wire-level event-property sanitisation + warning model.
//
// **Behaviour contract (matches Web/Node/RN exactly):**
//
//   sanitise + warn, NEVER throw.
//
// `track()` is fire-and-forget — making it throw on a single
// non-encodable property would break the consumer's call site in a
// way `try?` silently swallows. Instead: the validator returns a
// cleaned copy with non-encodable / unsafe values coerced or
// dropped, plus a list of warnings the consumer can route to a
// debug logger.
//
// Coercion rules:
//   * `Date`               → ISO 8601 string
//   * `URL`                → absoluteString
//   * `UUID`               → string
//   * `Double.nan / inf`   → NSNull, warning emitted
//   * `Float.nan / inf`    → NSNull, warning emitted
//   * `String` > maxStr    → truncated with ellipsis, warning emitted
//   * Cyclic NS containers → `"[circular]"`, warning emitted
//   * Depth > maxDepth     → `"[depth-exceeded]"`, warning emitted
//   * Non-encodable class  → dropped, warning emitted
//
// All warning kinds match the Web/Node/RN `ValidationWarning.kind`
// taxonomy so cross-platform consumers can wire one debug-routing
// pipeline across all SDKs.

import Foundation

/// Maximum string length on any single property value. Strings
/// longer than this get truncated with an ellipsis suffix.
public let maxStringLength: Int = 1024

/// Maximum nesting depth before the validator stops recursing.
public let validationMaxDepth: Int = 32

/// Reason a property was modified during sanitisation. Matches the
/// Web/Node/RN `ValidationWarning.kind` enum exactly.
public enum ValidationWarningKind: String, Sendable {
    case depthExceeded = "depth_exceeded"
    case circularReference = "circular_reference"
    case truncatedString = "truncated_string"
    case nonSerialisable = "non_serialisable"
    case notFinite = "not_finite"
}

public struct ValidationWarning: Sendable, Equatable {
    public let key: String
    public let kind: ValidationWarningKind

    public init(key: String, kind: ValidationWarningKind) {
        self.key = key
        self.kind = kind
    }
}

/// `properties` holds the cleaned, JSON-encodable bag. Marked
/// `@unchecked Sendable` because the validator guarantees only
/// primitive JSON types survive the sanitise pass (String, Bool,
/// Int/Double/etc., Array, Dictionary, NSNull) — every reference
/// type that's not a JSON container is dropped. The compiler can't
/// prove this so we vouch for it.
public struct ValidationResult: @unchecked Sendable {
    public let properties: [String: Any]
    public let warnings: [ValidationWarning]
}

/// Sanitise an event property map. Returns the cleaned bag plus a
/// list of warnings. NEVER throws — the bank-grade contract is that
/// `track()` always proceeds, even when properties had to be
/// coerced. Warnings are surfaced via the debug logger; the cleaned
/// bag is what ships on the wire.
public func validateEventProperties(_ properties: [String: Any]) -> ValidationResult {
    var warnings: [ValidationWarning] = []
    var ancestors: [ObjectIdentifier] = []
    let cleaned = sanitiseValue(
        properties,
        key: "<root>",
        depth: 0,
        ancestors: &ancestors,
        warnings: &warnings
    )
    let bag = (cleaned as? [String: Any]) ?? [:]
    return ValidationResult(properties: bag, warnings: warnings)
}

private func sanitiseValue(
    _ value: Any?,
    key: String,
    depth: Int,
    ancestors: inout [ObjectIdentifier],
    warnings: inout [ValidationWarning]
) -> Any? {
    if depth > validationMaxDepth {
        warnings.append(ValidationWarning(key: key, kind: .depthExceeded))
        return "[depth-exceeded]"
    }

    guard let value else { return nil }

    // String — truncate if oversize.
    if let s = value as? String {
        if s.count > maxStringLength {
            warnings.append(ValidationWarning(key: key, kind: .truncatedString))
            return String(s.prefix(maxStringLength - 1)) + "…"
        }
        return s
    }

    if value is Bool { return value }

    // Numerics: reject NaN / infinity (no JSON representation).
    if let d = value as? Double {
        if !d.isFinite {
            warnings.append(ValidationWarning(key: key, kind: .notFinite))
            return NSNull()
        }
        return d
    }
    if let f = value as? Float {
        if !f.isFinite {
            warnings.append(ValidationWarning(key: key, kind: .notFinite))
            return NSNull()
        }
        return f
    }
    if value is Int || value is Int32 || value is Int64
        || value is UInt || value is UInt32 || value is UInt64 {
        return value
    }
    if value is NSNull { return value }

    // Coerce common Foundation types into JSON-friendly shapes.
    if let date = value as? Date {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
    if let url = value as? URL { return url.absoluteString }
    if let uuid = value as? UUID { return uuid.uuidString }

    // Reference-type containers — cycle-checked + recursive.
    if let dict = value as? NSDictionary {
        let id = ObjectIdentifier(dict)
        if ancestors.contains(id) {
            warnings.append(ValidationWarning(key: key, kind: .circularReference))
            return "[circular]"
        }
        ancestors.append(id)
        defer { ancestors.removeLast() }
        var out: [String: Any] = [:]
        for (k, v) in dict {
            let keyName = (k as? String) ?? "\(k)"
            if let cleaned = sanitiseValue(v, key: keyName, depth: depth + 1, ancestors: &ancestors, warnings: &warnings) {
                out[keyName] = cleaned
            }
        }
        return out
    }
    if let arr = value as? NSArray {
        let id = ObjectIdentifier(arr)
        if ancestors.contains(id) {
            warnings.append(ValidationWarning(key: key, kind: .circularReference))
            return "[circular]"
        }
        ancestors.append(id)
        defer { ancestors.removeLast() }
        var out: [Any] = []
        for (i, v) in arr.enumerated() {
            if let cleaned = sanitiseValue(v, key: "\(key)[\(i)]", depth: depth + 1, ancestors: &ancestors, warnings: &warnings) {
                out.append(cleaned)
            }
        }
        return out
    }

    // Value-type containers — Swift arrays + dicts can't cycle.
    if let arr = value as? [Any] {
        var out: [Any] = []
        for (i, v) in arr.enumerated() {
            if let cleaned = sanitiseValue(v, key: "\(key)[\(i)]", depth: depth + 1, ancestors: &ancestors, warnings: &warnings) {
                out.append(cleaned)
            }
        }
        return out
    }
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if let cleaned = sanitiseValue(v, key: k, depth: depth + 1, ancestors: &ancestors, warnings: &warnings) {
                out[k] = cleaned
            }
        }
        return out
    }

    // Unknown reference type — not JSON-serialisable. Drop + warn.
    warnings.append(ValidationWarning(key: key, kind: .nonSerialisable))
    return nil
}
