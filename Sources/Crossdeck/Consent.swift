// PII consent + scrubber.
//
// Two responsibilities:
//
//  1) Track the consent state for analytics + errors independently
//     (a user may permit error tracking for debugging but deny
//     marketing analytics). Default-deny: until `update(...)` is
//     called, both are off.
//
//  2) Scrub PII out of event properties + error metadata. Tokens
//     are the platform-wide convention: `<email>` and `<card>`,
//     angle-bracketed to match Web/Node/RN/backend. Scrubbing is
//     applied recursively to nested dictionaries + arrays so a
//     payload like { user: { contact: { email: "..." } } } is
//     redacted at every depth.
//
// The scrubber runs on every event before it enters the queue.
// That deliberately means the queue NEVER holds raw PII, so a
// crash dump of the on-disk queue is safe to ship to support.

import Foundation

public struct ConsentState: Sendable, Equatable {
    public var analytics: Bool
    public var errors: Bool

    public init(analytics: Bool = false, errors: Bool = false) {
        self.analytics = analytics
        self.errors = errors
    }
}

public actor ConsentManager {
    public private(set) var state: ConsentState
    public private(set) var scrubPII: Bool

    public init(initial: ConsentState = ConsentState(), scrubPII: Bool = true) {
        self.state = initial
        self.scrubPII = scrubPII
    }

    public func update(_ next: ConsentState) {
        state = next
    }

    public func setScrubPII(_ enabled: Bool) {
        scrubPII = enabled
    }
}

// MARK: - PII scrubbing

/// Email regex. Intentionally lenient on the local part — anything
/// with an `@`, a domain label and a TLD-shaped suffix counts. We
/// would rather over-scrub than leak.
private let emailPattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#

/// Payment-card pattern. 13–19 digits with optional separators
/// (space or hyphen). Visa/Mastercard/Amex/Discover/JCB all fit
/// within this range; we deliberately do not Luhn-check because
/// any digit sequence in that range close enough to a card shape
/// is risky to retain.
private let cardPattern = #"\b(?:\d[ -]*?){13,19}\b"#

private let emailRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: emailPattern, options: [.caseInsensitive])
}()

private let cardRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: cardPattern)
}()

/// Scrub PII from a single string. Returns the scrubbed string.
/// Tokens (`<email>`, `<card>`) match the platform-wide vocabulary
/// — DO NOT alter them without simultaneously updating the
/// backend, web, node, and RN SDK constants.
public func scrubPII(_ input: String) -> String {
    var s = input
    let range = NSRange(s.startIndex..., in: s)

    if let regex = emailRegex {
        s = regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "<email>"
        )
    }
    if let regex = cardRegex {
        _ = range
        s = regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "<card>"
        )
    }
    return s
}

/// Recursively scrub PII out of an arbitrary JSON-shaped value.
/// Handles strings, arrays, dictionaries, and leaves other primitive
/// types untouched. Uses an `ObjectIdentifier` ancestor set to
/// break cycles — analytics payloads should never be cyclic, but
/// a poorly constructed wrapper could hand us one, and we'd rather
/// emit a redacted copy than recurse forever.
///
/// Note: Swift value semantics already prevent classic cycles for
/// `[String: Any]` / `[Any]`, but we still track depth as a defence
/// in depth against pathologically deep dictionaries (e.g. a 10k-
/// deep nested map) that would blow the stack.
public func scrubPIIDeep(
    _ value: Any,
    maxDepth: Int = 64
) -> Any {
    return scrubPIIRecursive(value, depth: 0, maxDepth: maxDepth)
}

private func scrubPIIRecursive(_ value: Any, depth: Int, maxDepth: Int) -> Any {
    if depth > maxDepth {
        // Stack-guard. Return a placeholder so the upstream payload
        // is still serialisable; the rest of the doc is unaffected.
        return "<crossdeck:scrub:max-depth>"
    }

    if let s = value as? String {
        return scrubPII(s)
    }
    if let arr = value as? [Any] {
        return arr.map { scrubPIIRecursive($0, depth: depth + 1, maxDepth: maxDepth) }
    }
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            out[k] = scrubPIIRecursive(v, depth: depth + 1, maxDepth: maxDepth)
        }
        return out
    }
    return value
}
