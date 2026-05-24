// Wire-level event validation + DAG-safe circular detection.
//
// Two failure modes we have to defend against before an event
// reaches the queue:
//
//  1) Caller-provided shapes that JSONSerialization will reject —
//     a CGFloat.nan property, a Date with no encoder, an opaque
//     class instance. We surface those as `invalid_request_error`
//     up-front rather than letting the queue blow up at flush time
//     (where the failure is asynchronous and harder to attribute).
//
//  2) Cyclic object graphs. Swift's `[String: Any]` doesn't
//     naturally cycle, but a class-type value inside the dictionary
//     can hold a reference back to the dictionary's container. We
//     walk the graph keeping an ancestor stack of class identities
//     and refuse to recurse into an already-seen ancestor.
//
// "DAG-safe" means: a diamond — same leaf reached via two
// independent ancestor chains — is allowed. Only a true cycle
// (an ancestor reachable from itself) trips the guard. The
// implementation matches the web/RN SDK pattern: add to the
// ancestor set on entry, REMOVE on exit, so siblings don't
// poison each other.

import Foundation

/// Maximum depth before we declare the payload pathological.
/// 32 matches what JSON-Schema validators tend to draw as a
/// "deeply nested" threshold. A real analytics event has
/// 1–4 levels of nesting; anything past 32 is a bug or attack.
let validationMaxDepth = 32

/// Validate an event property map. Throws CrossdeckError on the
/// first violation. Caller pattern: try validateEventProperties(...)
/// before enqueue; on throw, surface the error to the caller of
/// `track()` synchronously.
public func validateEventProperties(_ properties: [String: Any]) throws {
    var ancestors: [ObjectIdentifier] = []
    try walkValidate(properties, key: "<root>", depth: 0, ancestors: &ancestors)
}

private func walkValidate(
    _ value: Any,
    key: String,
    depth: Int,
    ancestors: inout [ObjectIdentifier]
) throws {
    if depth > validationMaxDepth {
        throw CrossdeckError(
            type: .invalidRequest,
            code: "event_properties_too_deep",
            message: "Event properties exceed max nesting depth (\(validationMaxDepth))."
        )
    }

    // Primitive bail-outs (cheap path).
    if value is String || value is Bool { return }

    // Numerics: reject NaN / infinity since JSON has no representation.
    if let d = value as? Double {
        guard d.isFinite else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "event_property_not_finite",
                message: "Property '\(key)' is NaN or infinite — not JSON-encodable."
            )
        }
        return
    }
    if let f = value as? Float {
        guard f.isFinite else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "event_property_not_finite",
                message: "Property '\(key)' is NaN or infinite — not JSON-encodable."
            )
        }
        return
    }
    if value is Int || value is Int32 || value is Int64
        || value is UInt || value is UInt32 || value is UInt64 {
        return
    }

    // NSNull → JSON null (allowed).
    if value is NSNull { return }

    // Reference-type containers FIRST. NSMutableDictionary /
    // NSMutableArray bridge to [String: Any] / [Any] via Swift's
    // implicit-cast rules, so if we let the value-type branches run
    // first we'd lose the chance to track object identity for cycle
    // detection. Class containers can cycle; value-type containers
    // cannot.
    if let dict = value as? NSDictionary {
        // NSDictionary covers both immutable and NSMutableDictionary.
        // Skip the cycle check for the bridged-immutable case (which
        // is value-shaped and can't form an in-memory cycle) only by
        // checking that the value actually IS the same instance on
        // re-entry — ancestors.contains handles this naturally.
        let id = ObjectIdentifier(dict)
        if ancestors.contains(id) {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "event_properties_cyclic",
                message: "Property '\(key)' contains a cyclic reference."
            )
        }
        ancestors.append(id)
        defer { ancestors.removeLast() }
        for (k, v) in dict {
            let keyName = (k as? String) ?? "\(k)"
            try walkValidate(v, key: keyName, depth: depth + 1, ancestors: &ancestors)
        }
        return
    }

    if let arr = value as? NSArray {
        let id = ObjectIdentifier(arr)
        if ancestors.contains(id) {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "event_properties_cyclic",
                message: "Property '\(key)' contains a cyclic reference."
            )
        }
        ancestors.append(id)
        defer { ancestors.removeLast() }
        for (i, v) in arr.enumerated() {
            try walkValidate(v, key: "\(key)[\(i)]", depth: depth + 1, ancestors: &ancestors)
        }
        return
    }

    // Value-type containers. No cycle check needed — Swift value
    // semantics make in-memory cycles impossible for these.
    if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() {
            try walkValidate(v, key: "\(key)[\(i)]", depth: depth + 1, ancestors: &ancestors)
        }
        return
    }

    if let dict = value as? [String: Any] {
        for (k, v) in dict {
            try walkValidate(v, key: k, depth: depth + 1, ancestors: &ancestors)
        }
        return
    }

    // Unknown class instance → not JSON-serialisable.
    throw CrossdeckError(
        type: .invalidRequest,
        code: "event_property_not_encodable",
        message: "Property '\(key)' of type \(type(of: value)) cannot be encoded to JSON."
    )
}
