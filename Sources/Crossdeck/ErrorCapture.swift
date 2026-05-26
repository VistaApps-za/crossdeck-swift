// Uncaught-exception capture.
//
// Two roads into the SDK from the platform:
//
//  1) NSSetUncaughtExceptionHandler — Objective-C exceptions
//     that escape the runloop. These almost always indicate a
//     fatal bug (the app is about to be killed) but the handler
//     gives us a few hundred ms to ship one last event.
//
//  2) Manual captureError(_:handled:) for handled-in-catch errors.
//
// Both paths converge on a single dispatch method that runs the
// consumer's beforeSend hook, then ships the event via the
// configured capture sink.
//
// Crash-reporter coexistence: NSSetUncaughtExceptionHandler is a
// PROCESS-wide singleton. Crashlytics, Sentry, Bugsnag, and
// Firebase Crashlytics all want it. On install we CHAIN — capture
// the prior handler (whoever registered last before us) and
// invoke it AFTER our own snapshot. Existing crash reporters
// stay populated; we snapshot one last event before they kill
// the process.
//
// Feedback-loop defence: a self-request skip is wired so HTTP
// failures targeting the configured ingest endpoint are dropped
// from the error pipeline. Without it, a transient ingest 5xx
// would generate an $error event, which would itself fail to
// send, which would generate another error… a perfect storm.
//
// The `beforeSend` hook gives the consumer one last chance to
// filter or transform errors. If beforeSend returns nil, the
// error is dropped.

import Foundation

public typealias BeforeSendErrorHandler = @Sendable (_ event: CapturedError) -> CapturedError?

public struct CapturedError: Sendable, Codable {
    public let type: String
    public let message: String
    public let fingerprint: String
    public let stack: [ParsedStackFrame]
    public let breadcrumbs: [Breadcrumb]
    public let timestamp: Date
    public let handled: Bool

    public init(
        type: String,
        message: String,
        fingerprint: String,
        stack: [ParsedStackFrame],
        breadcrumbs: [Breadcrumb],
        timestamp: Date = Date(),
        handled: Bool
    ) {
        self.type = type
        self.message = message
        self.fingerprint = fingerprint
        self.stack = stack
        self.breadcrumbs = breadcrumbs
        self.timestamp = timestamp
        self.handled = handled
    }
}

/// Singleton-shaped error capture coordinator. Apple's exception
/// handler is a global C function, so we cannot make it per-
/// Crossdeck-instance — instead we install once and dispatch
/// through a process-wide weak reference to the active capture.
public final class ErrorCapture: @unchecked Sendable {
    public static let shared = ErrorCapture()
    private init() {}

    private let lock = NSLock()
    private var beforeSend: BeforeSendErrorHandler?
    private var captureHandler: (@Sendable (CapturedError) -> Void)?
    private var breadcrumbsSnapshot: (@Sendable () async -> [Breadcrumb])?
    private var selfHostname: String?
    private var installed = false

    /// Prior NSException handler captured at install time so we
    /// can chain into it after our own snapshot — preserving
    /// Crashlytics / Sentry / Bugsnag if they were registered
    /// before us.
    private var priorExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Wire the capture pipeline. ALWAYS sets the routing closure so
    /// manual `cd.captureError(...)` calls reach the queue — this
    /// MUST work regardless of whether the global uncaught-handler
    /// is installed. The OS-level NSSetUncaughtExceptionHandler is
    /// gated separately via [installGlobalHandler] so consumers
    /// running Crashlytics / Sentry as their primary crash reporter
    /// can opt out of our global hook without losing manual capture.
    ///
    /// Idempotent — calling twice replaces the routing closures.
    public func install(
        beforeSend: BeforeSendErrorHandler?,
        breadcrumbs: @escaping @Sendable () async -> [Breadcrumb],
        selfHostname: String?,
        capture: @escaping @Sendable (CapturedError) -> Void,
        installGlobalHandler: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.beforeSend = beforeSend
        self.captureHandler = capture
        self.breadcrumbsSnapshot = breadcrumbs
        self.selfHostname = selfHostname

        if installGlobalHandler && !installed {
            installed = true
            // Chain into whatever handler was registered before us
            // (Crashlytics, Sentry, etc.). If we don't capture this,
            // we silently break every other crash reporter on the
            // device.
            self.priorExceptionHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                ErrorCapture.shared.captureFromExceptionHandler(exception)
            }
        }
    }

    /// Stop capturing. Removes the handler routing but leaves the
    /// global handler installed — Apple does not provide a clean
    /// way to remove NSSetUncaughtExceptionHandler, so subsequent
    /// uncaught exceptions will hit the chained prior handler (or
    /// nothing) until install() is called again.
    public func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        self.beforeSend = nil
        self.captureHandler = nil
        self.breadcrumbsSnapshot = nil
        self.selfHostname = nil
    }

    /// Manual capture path for handled errors (do/catch flows).
    public func captureError(
        _ error: Error,
        handled: Bool = true
    ) {
        // Self-request skip: if the error is a URLError whose URL
        // host matches our ingest endpoint, drop it before any
        // processing — these errors are the SDK observing its own
        // failed network calls (typically wrapped by a consumer's
        // logging middleware) and reporting them feeds a loop.
        let selfHostnameCopy = lock.withLock { self.selfHostname }
        if let selfHostnameCopy, errorMatchesSelfHost(error, host: selfHostnameCopy) {
            return
        }

        let stack = Thread.callStackSymbols
        let frames = parseStackSymbols(stack)
        let fingerprint = fingerprintFromStack(stack)

        let typeName: String
        let message: String
        if let cd = error as? CrossdeckError {
            typeName = "CrossdeckError.\(cd.type.rawValue)"
            message = cd.message
        } else {
            typeName = String(describing: type(of: error))
            message = String(describing: error)
        }

        let breadcrumbsProvider = lock.withLock { self.breadcrumbsSnapshot }
        Task {
            let crumbs = await breadcrumbsProvider?() ?? []
            let event = CapturedError(
                type: typeName,
                message: message,
                fingerprint: fingerprint,
                stack: frames,
                breadcrumbs: crumbs,
                handled: handled
            )
            dispatch(event)
        }
    }

    private func captureFromExceptionHandler(_ exception: NSException) {
        let stack = exception.callStackSymbols
        let frames = parseStackSymbols(stack)
        let fingerprint = fingerprintFromStack(stack)

        let event = CapturedError(
            type: "NSException.\(exception.name.rawValue)",
            message: exception.reason ?? "<unknown>",
            fingerprint: fingerprint,
            stack: frames,
            breadcrumbs: [], // No async access from the C handler
            handled: false
        )
        dispatch(event)

        // Chain into the prior handler (Crashlytics, Sentry, …)
        // AFTER our snapshot so their crash report still fires.
        // We never want to be the reason an upstream reporter
        // loses a crash.
        let prior = lock.withLock { self.priorExceptionHandler }
        prior?(exception)
    }

    private func dispatch(_ event: CapturedError) {
        let (beforeSendCopy, captureCopy): (BeforeSendErrorHandler?, (@Sendable (CapturedError) -> Void)?) = lock.withLock {
            return (beforeSend, captureHandler)
        }

        let final: CapturedError?
        if let beforeSendCopy {
            // Safety net — if user's beforeSend throws / fatals,
            // we'd rather lose the hook than the event. Swift
            // can't catch fatalError from a closure; the best
            // we can do is not let beforeSend's silence cause an
            // accidental drop further down the pipeline.
            final = beforeSendCopy(event)
        } else {
            final = event
        }

        guard let final, let captureCopy else { return }
        captureCopy(final)
    }

    /// True iff the error's underlying URL (if any) targets the
    /// SDK's own ingest endpoint. Used to break the feedback loop
    /// where reporting a failed ingest triggers another failed
    /// ingest report.
    private func errorMatchesSelfHost(_ error: Error, host: String) -> Bool {
        if let urlError = error as? URLError, let urlHost = urlError.failingURL?.host {
            return urlHost.lowercased() == host.lowercased()
        }
        if let cdError = error as? CrossdeckError,
           cdError.message.range(of: host, options: .caseInsensitive) != nil {
            return true
        }
        // String-based catch-all for arbitrary error types that
        // serialise to descriptions containing the endpoint URL.
        let description = String(describing: error)
        return description.range(of: host, options: .caseInsensitive) != nil
    }
}

// MARK: - Lock helper

private extension NSLock {
    func withLock<T>(_ block: () -> T) -> T {
        lock(); defer { unlock() }
        return block()
    }
}
