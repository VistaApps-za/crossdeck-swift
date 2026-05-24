// Structured debug-signal vocabulary.
//
// Mirrors `DebugSignal` in the Web/Node SDKs. Every internal event
// the SDK logs goes through this enum so a consumer who turns on
// debug mode sees a consistent, greppable trail. The vocabulary
// is the contract — adding a new internal log without giving it a
// signal name is a code-review red flag (the consumer's debug
// pipeline can't filter / route on freeform strings).

import Foundation
import os

public enum DebugSignal: String, Sendable {
    // Lifecycle
    case sdkStart = "sdk.start"
    case sdkStop = "sdk.stop"
    case sdkAlreadyStarted = "sdk.already_started"

    // Identity
    case identityIdentify = "identity.identify"
    case identityReset = "identity.reset"
    case identityHydrate = "identity.hydrate"

    // Queue
    case queueEnqueue = "queue.enqueue"
    case queueFlushStart = "queue.flush_start"
    case queueFlushOk = "queue.flush_ok"
    case queueFlushFail = "queue.flush_fail"
    case queueFlushRetry = "queue.flush_retry"
    case queueFlushPermanentFailure = "sdk.flush_permanent_failure"
    case queueOverflow = "queue.overflow"

    // Errors
    case errorCapture = "error.capture"
    case errorBeforeSendDropped = "error.before_send_dropped"
    case errorScrubFailed = "error.scrub_failed"

    // Consent
    case consentChange = "consent.change"
    case consentDenied = "consent.denied"

    // Validation
    case validationFailed = "validation.failed"

    // Entitlements
    case entitlementHydrate = "entitlement.hydrate"
    case entitlementWrite = "entitlement.write"
    case entitlementClear = "entitlement.clear"
}

/// Closure invoked for each debug signal. Sendable so it can be
/// invoked from inside the queue actor without contention.
public typealias DebugLogger = @Sendable (_ signal: DebugSignal, _ payload: [String: String]) -> Void

/// Default logger backed by Apple's unified logging system. Uses
/// the `info` level so production builds collect signals without
/// flooding `error` / `fault` channels — operators who want the
/// signals out of the device console can filter on subsystem.
public func defaultDebugLogger() -> DebugLogger {
    let log = Logger(subsystem: "com.crossdeck.sdk", category: "debug")
    return { signal, payload in
        if payload.isEmpty {
            log.info("\(signal.rawValue, privacy: .public)")
        } else {
            // Stable, sorted payload rendering so log diffing across
            // builds doesn't whiplash on dictionary iteration order.
            let kv = payload.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            log.info("\(signal.rawValue, privacy: .public) \(kv, privacy: .public)")
        }
    }
}

/// No-op logger. Default for SDK consumers who haven't opted into
/// debug mode — has zero allocation cost on the hot path.
public let noopDebugLogger: DebugLogger = { _, _ in }
