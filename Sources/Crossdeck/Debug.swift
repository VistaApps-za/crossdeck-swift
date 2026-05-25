// Structured debug signal vocabulary.
//
// **CANONICAL CONTRACT — matches Web/Node/RN exactly.** The
// platform-wide signal vocabulary is defined per NorthStar §16:
// the dashboard's onboarding checklist keys off these specific
// signal names so it can show "we saw your first event" without
// parsing free-form output. Renaming a signal is a BREAKING
// dashboard change.
//
// Signal names are stable across Web, Node, RN, and Swift. A
// cross-platform team that wires debug routing to a signal name
// in one SDK gets the same signal name on every other SDK.

import Foundation
import os

/// Canonical signal set (NorthStar §16). Every signal name on this
/// enum exists in `sdks/web/src/debug.ts` and the Node + RN
/// equivalents — zero drift.
public enum DebugSignal: String, Sendable {
    /// SDK successfully constructed + ready to accept track/identify.
    /// Carries `{ appId, environment, sdkName, sdkVersion }`.
    case sdkConfigured = "sdk.configured"

    /// First event of this process landed at the ingest endpoint.
    /// One-shot — fires once per process lifetime.
    case sdkFirstEventSent = "sdk.first_event_sent"

    /// `publicKey` doesn't start with `cd_pub_` (or doesn't match
    /// any known prefix). Always loud — published as an error.
    case sdkInvalidKey = "sdk.invalid_key"

    /// `track()` fired without a known `developerUserId` AND no
    /// stored `anonymousId` — degenerate case usually meaning
    /// storage failed.
    case sdkNoIdentity = "sdk.no_identity"

    /// `isEntitled(...)` answered from the local cache without a
    /// network round-trip. Tells the consumer the cache is warm.
    case sdkEntitlementCacheUsed = "sdk.entitlement_cache_used"

    /// Purchase receipt or rail evidence successfully sent.
    /// Currently emitted only by Web/Node; Swift v1.1 will fire
    /// it from the StoreKit purchase path.
    case sdkPurchaseEvidenceSent = "sdk.purchase_evidence_sent"

    /// Configured `environment` doesn't match the `publicKey`
    /// prefix. Surfaced at start; the SDK refuses to construct.
    case sdkEnvironmentMismatch = "sdk.environment_mismatch"

    /// A property key looks like PII (`email`, `password`,
    /// `token`, `secret`, `card`, `phone`). Warning-level —
    /// the property is shipped, but the consumer should review.
    case sdkSensitivePropertyWarning = "sdk.sensitive_property_warning"

    /// A property value was coerced (Date → ISO, NaN → null,
    /// circular → "[circular]", etc.) during validation.
    case sdkPropertyCoerced = "sdk.property_coerced"

    /// Queue state successfully persisted to local storage.
    /// Emitted on every flush + on app-background.
    case sdkQueuePersisted = "sdk.queue_persisted"

    /// Queue state successfully rehydrated from local storage
    /// on start.
    case sdkQueueRestored = "sdk.queue_restored"

    /// Flush hit a retryable failure (5xx / 408 / 429 / network)
    /// and is scheduled for retry. Carries `{ attempt, delay_ms }`.
    case sdkFlushRetryScheduled = "sdk.flush_retry_scheduled"

    /// Queue dropped a batch — permanent 4xx OR retry budget
    /// exhausted. Always loud regardless of debug mode. The
    /// dropped events are routed to `onPermanentFailure` if set.
    case sdkFlushPermanentFailure = "sdk.flush_permanent_failure"

    /// Consent state changed via `setConsent(...)`.
    case sdkConsentChanged = "sdk.consent_changed"

    /// `track()` or `captureError()` was dropped because the
    /// relevant consent channel is off.
    case sdkConsentDenied = "sdk.consent_denied"

    /// Do-Not-Track was detected (Web only — emitted for parity).
    case sdkConsentDntApplied = "sdk.consent_dnt_applied"

    /// PII scrubber replaced an email or card on the wire. Counts
    /// for visibility — the original value is not logged.
    case sdkPiiScrubbed = "sdk.pii_scrubbed"
}

/// Closure invoked for each debug signal. Sendable so it can be
/// invoked from inside the queue actor without contention.
public typealias DebugLogger = @Sendable (_ signal: DebugSignal, _ payload: [String: String]) -> Void

/// Default logger backed by Apple's unified logging system. Uses
/// the `info` level so production builds collect signals without
/// flooding `error` / `fault` channels — operators who want the
/// signals out of the device console can filter on subsystem.
///
/// Apple's modern `Logger` API requires iOS 14 / macOS 11 / tvOS 14
/// / watchOS 7. On older OS versions we fall back to the legacy
/// `os_log` family (iOS 10+) so the SDK still compiles + runs
/// against `Package.swift`'s declared minimum (iOS 13). The signal
/// vocabulary is identical across both paths; only the underlying
/// logging API differs. Inspect either via Console.app filtering
/// on the `com.crossdeck.sdk` subsystem.
public func defaultDebugLogger() -> DebugLogger {
    if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
        let log = Logger(subsystem: "com.crossdeck.sdk", category: "debug")
        return { signal, payload in
            if payload.isEmpty {
                log.info("\(signal.rawValue, privacy: .public)")
            } else {
                let kv = payload.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                log.info("\(signal.rawValue, privacy: .public) \(kv, privacy: .public)")
            }
        }
    } else {
        let log = OSLog(subsystem: "com.crossdeck.sdk", category: "debug")
        return { signal, payload in
            if payload.isEmpty {
                os_log("%{public}@", log: log, type: .info, signal.rawValue)
            } else {
                let kv = payload.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                os_log("%{public}@ %{public}@", log: log, type: .info, signal.rawValue, kv)
            }
        }
    }
}

/// No-op logger. Default for SDK consumers who haven't opted into
/// debug mode — has zero allocation cost on the hot path.
public let noopDebugLogger: DebugLogger = { _, _ in }

// MARK: - Sensitive-property name detection

/// Property-name patterns that almost always indicate PII or secret
/// data on the wire. Per NorthStar §15, `track()` warns the
/// developer when a property key matches these — we WARN rather
/// than REJECT because a property like `tokens_remaining` is a
/// legitimate use of the word.
///
/// Patterns mirror `sdks/react-native/src/debug.ts` exactly so a
/// cross-platform team gets identical warnings regardless of SDK.
private let sensitiveKeyPatterns: [NSRegularExpression] = {
    let raws = [
        #"^email$"#,
        #"^password$"#,
        #"^token$"#,
        #"^secret$"#,
        #"^card$"#,
        #"^phone$"#,
        #"password"#,
        #"credit_?card"#,
    ]
    return raws.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}()

/// Returns the subset of property keys that look like PII names.
/// Used by `track()` to emit `sdk.sensitive_property_warning` in
/// debug mode without blocking the event.
public func findSensitivePropertyKeys(_ properties: [String: Any]?) -> [String] {
    guard let properties else { return [] }
    var hits: [String] = []
    for key in properties.keys {
        let range = NSRange(key.startIndex..., in: key)
        for pattern in sensitiveKeyPatterns {
            if pattern.firstMatch(in: key, options: [], range: range) != nil {
                hits.append(key)
                break
            }
        }
    }
    return hits
}
