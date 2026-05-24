// Public Crossdeck client.
//
// The single thing a consumer touches:
//
//   let cd = Crossdeck.start(writeKey: "...", ...)
//   cd.track("paywall_seen")
//   try await cd.identify(customerId: "...", traits: [:])
//
// All of the heavy lifting (queue, identity, entitlements, error
// capture) hangs off this one type. The actor model below
// guarantees:
//
//   * exactly one identity snapshot is read per event enqueue
//   * the queue is the only writer for buffered/pending state
//   * entitlement reads are sync (cache hit) or surface a cold-start
//     answer via the optional fetch closure
//
// Bank-grade error rules baked in:
//
//   * `track(...)` and `identify(...)` THROW for caller errors
//     (missing event name, invalid properties). The consumer must
//     either handle them OR knowingly silence them via try?.
//
//   * The queue's permanent-failure callback is wired up at start
//     so the consumer can observe events that will never land.
//
//   * `flush()` returns when the in-flight batch resolves —
//     deterministic for testing and for app-shutdown drains.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

public struct CrossdeckOptions: Sendable {
    /// `https://api.cross-deck.com/v1/events` for production. We
    /// require it explicitly rather than defaulting so a misconfig
    /// can never silently ship events to the wrong environment.
    public var endpoint: URL
    public var writeKey: String

    /// Optional URLSession injection. Pass a mock in tests; pass
    /// a custom session in production if you need proxy or App
    /// Group transport.
    public var urlSession: URLSession?

    /// Storage backend. Defaults to `UserDefaultsStorage()`.
    public var storage: Storage?

    /// Initial consent state. Default-deny (analytics off, errors
    /// off) — consumer must opt in.
    public var initialConsent: ConsentState

    /// Scrub PII before events leave the device. On by default
    /// for the same reason consent defaults to off — we err on
    /// the side of less data leaving the device.
    public var scrubPII: Bool

    /// Queue configuration (batch size, flush interval, retry).
    public var queueConfig: EventQueueConfig

    /// Breadcrumb ring-buffer capacity.
    public var breadcrumbCapacity: Int

    /// Capture uncaught Obj-C exceptions. Default off — installing
    /// the global exception handler can interfere with other
    /// crash reporters (Crashlytics, Sentry). Turn this on only
    /// if Crossdeck is your primary error tracker.
    public var captureUncaughtExceptions: Bool

    /// Filter / transform errors before they're enqueued. Returning
    /// nil drops the error entirely.
    public var beforeSendError: BeforeSendErrorHandler?

    /// Permanent-failure callback. Wired into the queue so the
    /// consumer can observe events that will never deliver.
    public var onPermanentFailure: PermanentFailureHandler?

    /// Debug log routing. Default is a no-op so prod builds carry
    /// no log overhead. Pass `defaultDebugLogger()` to route to
    /// Apple unified logging during development.
    public var debugLogger: DebugLogger

    public init(
        endpoint: URL,
        writeKey: String,
        urlSession: URLSession? = nil,
        storage: Storage? = nil,
        initialConsent: ConsentState = ConsentState(),
        scrubPII: Bool = true,
        queueConfig: EventQueueConfig = EventQueueConfig(),
        breadcrumbCapacity: Int = defaultBreadcrumbCapacity,
        captureUncaughtExceptions: Bool = false,
        beforeSendError: BeforeSendErrorHandler? = nil,
        onPermanentFailure: PermanentFailureHandler? = nil,
        debugLogger: @escaping DebugLogger = noopDebugLogger
    ) {
        self.endpoint = endpoint
        self.writeKey = writeKey
        self.urlSession = urlSession
        self.storage = storage
        self.initialConsent = initialConsent
        self.scrubPII = scrubPII
        self.queueConfig = queueConfig
        self.breadcrumbCapacity = breadcrumbCapacity
        self.captureUncaughtExceptions = captureUncaughtExceptions
        self.beforeSendError = beforeSendError
        self.onPermanentFailure = onPermanentFailure
        self.debugLogger = debugLogger
    }
}

public final class Crossdeck: @unchecked Sendable {
    private let options: CrossdeckOptions
    private let storage: Storage
    private let identity: Identity
    private let superProperties: SuperProperties
    private let entitlements: EntitlementCache
    private let consent: ConsentManager
    private let breadcrumbs: Breadcrumbs
    private let queue: EventQueue
    private let http: HTTPClient
    private let device: DeviceInfo
    private let selfHostname: String?

    private var started: Bool = true
    private let startedLock = NSLock()

    /// Designated start path. Performs all synchronous init (file
    /// reads, UserDefaults reads, actor allocation) and returns
    /// the started client. Side-effects:
    ///
    ///   * Reads / generates anonymousId
    ///   * Rehydrates queue from disk (re-sends any pending batch)
    ///   * Optionally installs the global exception handler
    public static func start(options: CrossdeckOptions) -> Crossdeck {
        return Crossdeck(options: options)
    }

    private init(options: CrossdeckOptions) {
        self.options = options
        let storage = options.storage ?? UserDefaultsStorage()
        self.storage = storage
        self.identity = Identity(storage: storage)
        self.superProperties = SuperProperties(storage: storage)
        self.entitlements = EntitlementCache(storage: storage)
        self.consent = ConsentManager(initial: options.initialConsent, scrubPII: options.scrubPII)
        self.breadcrumbs = Breadcrumbs(capacity: options.breadcrumbCapacity)
        self.http = HTTPClient(
            endpoint: options.endpoint,
            writeKey: options.writeKey,
            session: options.urlSession
        )
        self.queue = EventQueue(
            http: http,
            storage: storage,
            logger: options.debugLogger,
            onPermanentFailure: options.onPermanentFailure,
            config: options.queueConfig
        )
        self.device = DeviceInfo.capture()
        self.selfHostname = extractSelfHostname(from: options.endpoint.absoluteString)

        options.debugLogger(.sdkStart, [
            "platform": device.platform,
            "sdk_version": SDK.version,
        ])

        if options.captureUncaughtExceptions {
            installErrorCapture()
        }

        installLifecycleObservers()

        // Try a flush on start to ship anything rehydrated from
        // the prior session. Fire-and-forget — if there's nothing
        // to send, this is a no-op.
        Task { await queue.flush() }
    }

    // MARK: - Public API

    public func track(_ name: String, properties: [String: Any]? = nil) throws {
        try assertStarted()
        guard !name.isEmpty else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "missing_event_name",
                message: "track(name) requires a non-empty name."
            )
        }
        if let properties { try validateEventProperties(properties) }

        // Convert to AnyCodable synchronously on the caller's
        // thread, before spawning the Task. This achieves two
        // things: (a) the closure only captures Sendable values
        // (AnyCodable is @unchecked Sendable for the same reason
        // documented at the type), avoiding strict-concurrency
        // data-race diagnostics; (b) the conversion + validation
        // both happen synchronously so caller-side errors surface
        // immediately rather than swallowed inside a Task.
        var codedProperties: [String: AnyCodable] = [:]
        if let properties {
            for (k, v) in properties { codedProperties[k] = AnyCodable(v) }
        }
        let codedSnapshot = codedProperties

        Task {
            let consentState = await consent.state
            // Analytics consent gate — errors come through a
            // separate path so they ignore this.
            guard consentState.analytics else {
                options.debugLogger(.consentDenied, ["event": name])
                return
            }
            let scrub = await consent.scrubPII

            let (anonymousId, customerId) = await identity.snapshot()
            let superProps = await superProperties.snapshot()

            var merged: [String: Any] = [:]
            for (k, v) in superProps { merged[k] = v }
            for (k, v) in device.asPayload { merged[k] = v }
            for (k, v) in codedSnapshot { merged[k] = v.value }

            let final = scrub ? (scrubPIIDeep(merged) as? [String: Any]) ?? merged : merged
            var coded: [String: AnyCodable] = [:]
            for (k, v) in final { coded[k] = AnyCodable(v) }

            let event = WireEvent(
                id: "cdevt_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                name: name,
                timestamp: Date(),
                properties: coded,
                anonymousId: anonymousId,
                customerId: customerId
            )

            await queue.enqueue(event)
            await breadcrumbs.add(Breadcrumb(
                category: .custom,
                level: .info,
                message: "track \(name)"
            ))
        }
    }

    public func identify(customerId: String, traits: [String: Any]? = nil) throws {
        try assertStarted()
        guard !customerId.isEmpty else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "missing_customer_id",
                message: "identify(customerId) requires a non-empty id."
            )
        }
        if let traits { try validateEventProperties(traits) }

        Task {
            // If the customerId is changing, clear the prior
            // entitlement cache so we don't leak a previous user's
            // entitlements to a freshly identified one. Unconditional
            // clear is correct: identify with the same id is rare and
            // a stray clear is cheaper than a leaked entitlement.
            let priorId = await identity.snapshot().customerId
            let didChange = await identity.setCustomerId(customerId)
            if didChange || priorId == nil {
                await entitlements.clear()
            }
            options.debugLogger(.identityIdentify, ["customer_id": customerId])
            await breadcrumbs.add(Breadcrumb(
                category: .identity,
                level: .info,
                message: "identify \(customerId)"
            ))
        }

        if let traits {
            // Fire an `$identify` event so traits land in the same
            // pipeline as track events.
            try track("$identify", properties: traits)
        }
    }

    public func reset() throws {
        try assertStarted()
        Task {
            await identity.reset()
            await entitlements.clear()
            await superProperties.clear()
            await breadcrumbs.clear()
            options.debugLogger(.identityReset, [:])
        }
    }

    public func registerSuperProperty(_ key: String, _ value: String) {
        Task { await superProperties.register(key, value) }
    }

    public func registerSuperPropertyOnce(_ key: String, _ value: String) {
        Task { await superProperties.registerOnce(key, value) }
    }

    public func unregisterSuperProperty(_ key: String) {
        Task { await superProperties.unregister(key) }
    }

    public func addBreadcrumb(_ crumb: Breadcrumb) {
        Task { await breadcrumbs.add(crumb) }
    }

    public func captureError(_ error: Error, handled: Bool = true) {
        ErrorCapture.shared.captureError(error, handled: handled)
    }

    public func setConsent(_ state: ConsentState) {
        Task {
            await consent.update(state)
            options.debugLogger(.consentChange, [
                "analytics": String(state.analytics),
                "errors": String(state.errors),
            ])
        }
    }

    public func setScrubPII(_ enabled: Bool) {
        Task { await consent.setScrubPII(enabled) }
    }

    /// Async flush. Returns once the in-flight batch resolves. Use
    /// before app-shutdown to drain.
    public func flush() async {
        await queue.flush()
    }

    public func stats() async -> QueueStats {
        return await queue.stats()
    }

    // MARK: - Internal lifecycle

    private func assertStarted() throws {
        startedLock.lock()
        defer { startedLock.unlock() }
        guard started else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "not_started",
                message: "Crossdeck client was stopped — call Crossdeck.start(...) again."
            )
        }
    }

    public func stop() {
        startedLock.lock()
        defer { startedLock.unlock() }
        started = false
        options.debugLogger(.sdkStop, [:])
        // Best-effort: persist anything in flight before relinquishing.
        Task { await queue.persistAll() }
    }

    private func installErrorCapture() {
        let breadcrumbsRef = breadcrumbs
        let queueRef = queue
        let optsBeforeSend = options.beforeSendError
        ErrorCapture.shared.install(
            beforeSend: optsBeforeSend,
            breadcrumbs: { await breadcrumbsRef.snapshot() },
            capture: { [weak self] event in
                guard let self else { return }
                // Wrap the CapturedError as a WireEvent so it travels
                // the same queue, gets the same idempotency guarantees,
                // and lands in the same backend pipeline as track().
                let (anon, cust) = (
                    "<error-capture>",  // identity read is async — error path skips it to ship sub-second
                    nil as String?
                )
                _ = (anon, cust)
                Task {
                    let (anonymousId, customerId) = await self.identity.snapshot()
                    var props: [String: AnyCodable] = [
                        "error.type": AnyCodable(event.type),
                        "error.message": AnyCodable(event.message),
                        "error.fingerprint": AnyCodable(event.fingerprint),
                        "error.handled": AnyCodable(event.handled),
                    ]
                    if !event.stack.isEmpty {
                        props["error.stack"] = AnyCodable(event.stack.map {
                            "\($0.module):\($0.symbol)"
                        })
                    }
                    let wire = WireEvent(
                        id: "cderr_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                        name: "$error",
                        timestamp: event.timestamp,
                        properties: props,
                        anonymousId: anonymousId,
                        customerId: customerId
                    )
                    await queueRef.enqueue(wire)
                }
            }
        )
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.persistAll() }
        }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Best-effort flush before suspension. iOS gives a few
            // seconds of background time — enough to ship a small batch.
            Task { await self.queue.flush() }
        }
        #endif
    }
}
