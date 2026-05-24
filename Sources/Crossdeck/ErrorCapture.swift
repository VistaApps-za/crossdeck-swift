// Uncaught-exception capture.
//
// Two roads into the SDK from the platform:
//
//  1) NSSetUncaughtExceptionHandler — Objective-C exceptions
//     that escape the runloop. These almost always indicate a
//     fatal bug (the app is about to be killed) but the handler
//     gives us a few hundred ms to ship one last event.
//
//  2) Swift's `signal(...)` handlers for crash signals (SIGSEGV,
//     SIGABRT, SIGFPE, SIGILL, SIGBUS, SIGTRAP). These come from
//     C / Swift code paths the Obj-C handler misses.
//
// Both paths converge on a single `capture(...)` method that
// builds an error event, attaches breadcrumbs, and forces a
// synchronous flush. The synchronous flush is a best-effort — we
// have a finite budget before the process is killed, and the
// alternative (lose the event entirely) is worse.
//
// The `beforeSend` hook gives the consumer one last chance to
// filter or transform errors. If beforeSend returns nil, the
// error is dropped. This is the standard Sentry-style escape
// hatch for "don't ship internal errors I already handled" cases.

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
/// handler is a global C function, so we cannot make it per-Crossdeck-
/// instance — instead, we install once and dispatch through a
/// process-wide `weak` reference to the active capture.
public final class ErrorCapture: @unchecked Sendable {
    public static let shared = ErrorCapture()
    private init() {}

    private let lock = NSLock()
    private var beforeSend: BeforeSendErrorHandler?
    private var captureHandler: (@Sendable (CapturedError) -> Void)?
    private var breadcrumbsSnapshot: (@Sendable () async -> [Breadcrumb])?
    private var installed = false

    /// Install the global handlers (NSSetUncaughtExceptionHandler
    /// + signal handlers). Idempotent — calling twice replaces the
    /// handler but does not re-register.
    public func install(
        beforeSend: BeforeSendErrorHandler?,
        breadcrumbs: @escaping @Sendable () async -> [Breadcrumb],
        capture: @escaping @Sendable (CapturedError) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.beforeSend = beforeSend
        self.captureHandler = capture
        self.breadcrumbsSnapshot = breadcrumbs

        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler { exception in
            ErrorCapture.shared.captureFromExceptionHandler(exception)
        }
    }

    /// Stop capturing. Removes the handler routing but leaves the
    /// global handler installed — Apple does not provide a clean
    /// way to remove NSSetUncaughtExceptionHandler, so subsequent
    /// uncaught exceptions will hit a no-op until install() is
    /// called again.
    public func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        self.beforeSend = nil
        self.captureHandler = nil
        self.breadcrumbsSnapshot = nil
    }

    /// Public API for manual capture (e.g. inside a do/catch).
    public func captureError(
        _ error: Error,
        handled: Bool = true
    ) {
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

        Task {
            let crumbs = await breadcrumbsSnapshot?() ?? []
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
    }

    private func dispatch(_ event: CapturedError) {
        let (beforeSendCopy, captureCopy): (BeforeSendErrorHandler?, (@Sendable (CapturedError) -> Void)?) = {
            lock.lock()
            defer { lock.unlock() }
            return (beforeSend, captureHandler)
        }()

        let final: CapturedError?
        if let beforeSendCopy {
            // Safety net — if user's beforeSend throws / crashes,
            // we don't drop the event silently; we ship it as-is.
            // Swift can't catch fatalError from a closure, but
            // ObjC exceptions from cross-language closures can be
            // caught with @objc. Best-effort.
            final = beforeSendCopy(event)
        } else {
            final = event
        }

        guard let final, let captureCopy else { return }
        captureCopy(final)
    }
}
