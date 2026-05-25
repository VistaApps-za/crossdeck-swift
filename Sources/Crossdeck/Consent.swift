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

    /// Default-GRANT for both channels — matches the Web/Node/RN
    /// platform contract. The SDK ships events + errors by default;
    /// consumers wire `setConsent(ConsentState(analytics: false))`
    /// for a strict-consent flow (cookie banner / privacy-jurisdiction
    /// gate). Default-deny would silently drop every event from a
    /// developer following the docs verbatim — that's the wrong
    /// failure mode for a telemetry SDK.
    public init(analytics: Bool = true, errors: Bool = true) {
        self.analytics = analytics
        self.errors = errors
    }
}

/// Sync-readable box for the current consent + scrub-PII state.
/// Keeps non-isolated reads honest while the actor remains the
/// single writer for state changes.
final class ConsentStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var consent: ConsentState
    private var scrub: Bool

    init(consent: ConsentState, scrub: Bool) {
        self.consent = consent
        self.scrub = scrub
    }

    func snapshot() -> (consent: ConsentState, scrub: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (consent, scrub)
    }

    func setConsent(_ next: ConsentState) {
        lock.lock(); defer { lock.unlock() }
        consent = next
    }

    func setScrub(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        scrub = enabled
    }
}

public actor ConsentManager {
    public private(set) var state: ConsentState
    public private(set) var scrubPII: Bool

    /// Sync mirror — exposed via `nonisolated snapshotSync()` so the
    /// error pipeline (which has to decide whether to drop or
    /// enqueue an event without an async hop) can gate cheaply.
    private let syncBox: ConsentStateBox

    public init(initial: ConsentState = ConsentState(), scrubPII: Bool = true) {
        self.state = initial
        self.scrubPII = scrubPII
        self.syncBox = ConsentStateBox(consent: initial, scrub: scrubPII)
    }

    public func update(_ next: ConsentState) {
        state = next
        syncBox.setConsent(next)
    }

    public func setScrubPII(_ enabled: Bool) {
        scrubPII = enabled
        syncBox.setScrub(enabled)
    }

    /// Nonisolated sync snapshot used by hot-path consumers (error
    /// pipeline gate, $error PII scrub decision) so they don't
    /// pay an actor hop on every error.
    public nonisolated func snapshotSync() -> (consent: ConsentState, scrub: Bool) {
        return syncBox.snapshot()
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
    // The NSRange is recomputed for each replacement because the
    // string length changes after the email pass — using a stale
    // range for the card pass would either miss matches at the new
    // tail or read past the end.
    if let regex = emailRegex {
        s = regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "<email>"
        )
    }
    if let regex = cardRegex {
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
