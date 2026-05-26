// Public Crossdeck client.
//
// The single thing a consumer touches:
//
//   let cd = try Crossdeck.start(options: CrossdeckOptions(
//       appId: "app_ios_xxx",
//       publicKey: "cd_pub_live_…",
//       environment: .production
//   ))
//   try cd.track("paywall_seen")
//   try cd.identify(userId: "user_847", email: "wes@example.com")
//
// **Vocabulary contract — locked to Web/Node/RN.** Public identity
// methods use `userId` for the consumer's auth-provider ID and
// `email` as a first-class top-level option. NEVER `customerId` —
// that name collides with `crossdeckCustomerId` (the cdcust_…
// canonical handle) which is a different concept entirely.
// Cross-platform teams reading the identify-users doc expect these
// exact names; any drift fragments their users in production.
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

#if canImport(AppKit)
import AppKit
#endif

#if canImport(WatchKit) && os(watchOS)
import WatchKit
#endif

/// Environment declaration — must match the `publicKey` prefix.
/// Mismatch is rejected at `Crossdeck.start(...)` so a typo'd key
/// can't silently route production telemetry into sandbox
/// dashboards.
public enum Environment: String, Sendable, Codable {
    case production
    case sandbox
}

public struct CrossdeckOptions: Sendable {
    /// Crossdeck App ID issued in the dashboard
    /// (e.g. `app_ios_xxx`). Required. Goes on every batch envelope
    /// so the backend can correlate events with the specific app
    /// surface and reject mismatched env declarations (`env_mismatch`).
    public var appId: String

    /// Crossdeck publishable key (`cd_pub_live_…` / `cd_pub_test_…`).
    /// Required. Safe to embed in a shipping `.ipa` — can only POST
    /// events and read entitlements, never grant features or read
    /// other customers' data.
    public var publicKey: String

    /// Explicit environment declaration. Required. Must match the
    /// `publicKey` prefix — `cd_pub_live_…` ↔ `.production`,
    /// `cd_pub_test_…` ↔ `.sandbox`. Mismatch is rejected at
    /// `Crossdeck.start(...)`.
    public var environment: Environment

    /// Override the API base URL. Default `https://api.cross-deck.com/v1`.
    /// Useful for self-hosted setups or the local emulator. When
    /// overridden, the SDK's error-capture self-skip pivots off
    /// THIS URL's hostname.
    public var baseUrl: URL?

    /// Optional URLSession injection. Pass a mock in tests; pass a
    /// custom session in production if you need proxy or App
    /// Group transport.
    public var urlSession: URLSession?

    /// Storage backend. Defaults to `UserDefaultsStorage()`.
    public var storage: Storage?

    /// Initial consent state. Default-GRANT both channels — matches
    /// Web/Node/RN platform contract. Consumers wire an opt-out via
    /// `setConsent(...)` for strict-consent flows (cookie banner,
    /// EU AGE-verification gate).
    public var initialConsent: ConsentState

    /// Scrub PII before events leave the device. On by default —
    /// emails and card numbers in property values are replaced with
    /// `<email>` / `<card>` tokens before the event enters the queue.
    /// Disable only when you have a hard requirement and explicit
    /// consent to ship raw values.
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

    /// Auto-tracking configuration. Default-everything-on — sessions,
    /// screen views via `page.viewed`, tap autocapture via
    /// `element.clicked`. Pass `.off` for strict-consent flows where
    /// the SDK must emit zero events before user opt-in.
    ///
    /// Cross-platform contract: same event names as the Web/Node/RN
    /// SDKs — `session.started`, `session.ended`, `page.viewed`,
    /// `element.clicked` — so a single dashboard query for any of
    /// these names returns Web + iOS + Android rows uniformly. The
    /// `platform` property (added automatically on every event by
    /// the device-info enricher) discriminates when needed.
    public var autoTrack: AutoTrackConfig

    /// MetricKit-backed performance monitoring. Off by default
    /// because the daily payload can be large and not every customer
    /// wants the perf signal. Set to true to receive `perf.metrics`,
    /// `perf.hang`, `perf.cpu_exception`, `perf.disk_write_exception`,
    /// and `perf.crash_diagnostic` events. iOS 14+ only.
    public var enablePerformanceMonitoring: Bool

    /// Listen on `Transaction.updates` (StoreKit 2) automatically.
    /// When true, every signed transaction the system delivers
    /// (purchase, restore, renewal, refund, family-shared) flows
    /// to `/purchases/sync` AND fires a `purchase.completed` /
    /// `purchase.refunded` event. Off by default because most apps
    /// already invoke syncPurchases() from their own confirmation
    /// flow and don't want duplicate work. iOS 15+ only.
    public var automaticPurchaseTracking: Bool

    /// Proactively flush the event queue whenever network
    /// reachability transitions from offline → online (NWPathMonitor).
    /// Default ON because the latency improvement on intermittent
    /// connections (subway, airplane mode toggle) is large and the
    /// monitor has near-zero overhead. Set to false to rely solely
    /// on the existing 5-second flush timer. iOS 12+ / macOS 10.14+.
    public var enableReachabilityFlush: Bool

    public init(
        appId: String,
        publicKey: String,
        environment: Environment,
        baseUrl: URL? = nil,
        urlSession: URLSession? = nil,
        storage: Storage? = nil,
        initialConsent: ConsentState = ConsentState(),
        scrubPII: Bool = true,
        queueConfig: EventQueueConfig = EventQueueConfig(),
        breadcrumbCapacity: Int = defaultBreadcrumbCapacity,
        captureUncaughtExceptions: Bool = false,
        beforeSendError: BeforeSendErrorHandler? = nil,
        onPermanentFailure: PermanentFailureHandler? = nil,
        debugLogger: @escaping DebugLogger = noopDebugLogger,
        autoTrack: AutoTrackConfig = .default,
        enablePerformanceMonitoring: Bool = false,
        automaticPurchaseTracking: Bool = false,
        enableReachabilityFlush: Bool = true
    ) {
        self.appId = appId
        self.publicKey = publicKey
        self.environment = environment
        self.baseUrl = baseUrl
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
        self.autoTrack = autoTrack
        self.enablePerformanceMonitoring = enablePerformanceMonitoring
        self.automaticPurchaseTracking = automaticPurchaseTracking
        self.enableReachabilityFlush = enableReachabilityFlush
    }

    /// Effective base URL — `baseUrl` if set, else the production
    /// default. Used by the HTTP client and the self-request skip.
    public var effectiveBaseUrl: URL {
        return baseUrl ?? URL(string: "https://api.cross-deck.com/v1")!
    }
}

/// Crossdeck client — the single instance a consumer holds for the
/// app's lifetime.
///
/// **Sendable conformance.** This class is `@unchecked Sendable`
/// because:
///
///   * Every reference-type stored property is a `let` and resolves
///     to a `Sendable` type (Swift actors, value-shape adapters
///     marked Sendable, or @unchecked-Sendable boxes that document
///     their own NSLock-based safety).
///   * The single mutable property (`started: Bool`) is protected
///     by `startedLock: NSLock` and only accessed via
///     `assertStarted()` / `stop()`.
///
/// Adding a new `var` to this class without lock-protecting it
/// would be a strict-concurrency violation the compiler will NOT
/// catch (because of the unchecked attribute). Code review must
/// enforce: any new mutable state goes inside an actor or behind
/// the existing lock pattern.
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

    /// AutoTracker unregister handle — call from stop() to drop
    /// this instance's auto-track listener. The singleton's
    /// observers + swizzles stay installed (un-swizzling is
    /// race-prone), but no more events flow to this client.
    private var autoTrackUnregister: (() -> Void)?

    /// Reachability monitor — fires queue.flush() on offline→online
    /// transitions. nil when `enableReachabilityFlush` is false or
    /// the OS target is below the NWPathMonitor floor.
    private var reachability: Any?

    /// MetricKit subscriber — nil when `enablePerformanceMonitoring`
    /// is false or the OS target is below the MetricKit floor.
    private var performanceVitals: Any?

    /// StoreKit 2 Transaction.updates consumer — nil when
    /// `automaticPurchaseTracking` is false or the OS target is
    /// below iOS 15.
    private var purchaseAutoTrack: Any?

    // Process-singleton accessor — exposes the most-recently-started
    // client so services / view models / non-SwiftUI surfaces can
    // reach the SDK without an explicit injection. SwiftUI views
    // should still prefer @Environment(\.crossdeck) inside body { };
    // DI users can keep injecting the instance explicitly. The
    // accessor is thread-safe via `currentLock` and Optional-typed
    // so the call-site idiom is the same `cd?.` propagation used in
    // the Quickstart pattern.
    //
    // Bank-grade discipline: never falsely report a stopped client
    // as current. `stop()` clears the slot iff the stopped instance
    // is the one currently advertised — concurrent start+stop races
    // on a SECOND client don't clobber the FIRST one's slot.
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: Crossdeck?

    /// Runtime-mutable error capture context. Protected by
    /// `errorStateLock`. The ErrorCapture pipeline reads through
    /// these on every captured event so `setTag` / `setContext` /
    /// `setErrorBeforeSend` take effect for the NEXT error after
    /// the call, matching Web/Node/RN behaviour.
    private let errorStateLock = NSLock()
    private var errorTags: [String: String] = [:]
    private var errorContext: [String: [String: String]] = [:]
    private var runtimeBeforeSend: BeforeSendErrorHandler?

    /// Designated start path. Performs all synchronous init (file
    /// reads, UserDefaults reads, actor allocation) and returns
    /// the started client. Side-effects:
    ///
    ///   * Validates `publicKey` (must start with `cd_pub_`).
    ///   * Validates `environment` against the key prefix
    ///     (`cd_pub_live_…` → `.production`,
    ///     `cd_pub_test_…` → `.sandbox`).
    ///   * Reads / generates `anonymousId`.
    ///   * Rehydrates queue from disk (re-sends any pending batch).
    ///   * Optionally installs the global exception handler.
    ///
    /// Throws `CrossdeckError(code: "invalid_secret_key")` if the
    /// publicKey shape is wrong, or `env_mismatch` if the
    /// environment declaration doesn't match the key prefix.
    public static func start(options: CrossdeckOptions) throws -> Crossdeck {
        // Validate publicKey shape — must start with cd_pub_.
        guard options.publicKey.hasPrefix("cd_pub_") else {
            throw CrossdeckError(
                type: .authentication,
                code: "invalid_secret_key",
                message: "Crossdeck.start requires a publishable key starting with cd_pub_. Got prefix: \(String(options.publicKey.prefix(8)))…"
            )
        }
        // Validate env matches key prefix — same check Web/Node/RN
        // make to prevent a typo'd build configuration silently
        // routing production telemetry to sandbox dashboards.
        let expectedEnv: Environment = options.publicKey.hasPrefix("cd_pub_live_") ? .production : .sandbox
        guard options.environment == expectedEnv else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "env_mismatch",
                message: "publicKey prefix declares \(expectedEnv.rawValue) but options.environment is \(options.environment.rawValue). Fix one or the other before start."
            )
        }
        // App ID required and non-empty.
        guard !options.appId.isEmpty else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "missing_app_id",
                message: "Crossdeck.start requires a non-empty appId. Find yours in the Crossdeck dashboard."
            )
        }
        let instance = Crossdeck(options: options)
        // Publish to the process-singleton accessor AFTER construction
        // succeeds. `start()` only reaches this line after validation +
        // sync init returned, so consumers reading `Crossdeck.current`
        // from a different thread never observe a half-initialised
        // instance.
        currentLock.lock()
        _current = instance
        currentLock.unlock()
        return instance
    }

    /// The most-recently-started Crossdeck instance — process-wide
    /// singleton accessor.
    ///
    /// Use this from non-SwiftUI surfaces (services, view models,
    /// AppDelegate methods, Combine pipelines, background workers)
    /// where injecting the instance through `@Environment(\.crossdeck)`
    /// isn't an option. Returns `nil` before `start(...)` has ever
    /// succeeded in this process, or after the most-recently-started
    /// client's `stop()` was called.
    ///
    /// Inside SwiftUI views, prefer `@Environment(\.crossdeck)` — it
    /// participates in SwiftUI's dependency-tracking and avoids
    /// reaching across module boundaries. The static accessor exists
    /// for the 50% of the codebase that isn't a View.
    ///
    /// Thread-safe; safe to read concurrently from any actor / queue.
    public static var current: Crossdeck? {
        currentLock.lock()
        defer { currentLock.unlock() }
        return _current
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
        // Events endpoint = baseUrl + "/events". The /events path is
        // appended here so the consumer only has to think in terms
        // of base URLs (matches the Web/Node/RN convention).
        let eventsEndpoint = options.effectiveBaseUrl.appendingPathComponent("events")
        self.http = HTTPClient(
            endpoint: eventsEndpoint,
            publicKey: options.publicKey,
            session: options.urlSession
        )
        // Pass the envelope context (appId, environment, sdk) into
        // the queue so encodeBatch can build the canonical envelope
        // every Web/Node SDK already ships.
        self.queue = EventQueue(
            http: http,
            storage: storage,
            envelope: EventQueueEnvelope(
                appId: options.appId,
                environment: options.environment
            ),
            logger: options.debugLogger,
            onPermanentFailure: options.onPermanentFailure,
            config: options.queueConfig
        )
        self.device = DeviceInfo.capture()
        // Self-skip pivots on the configured base URL's host, NOT
        // the production default — so a staging or self-hosted
        // relay never recurses through its own fetch-wrap.
        self.selfHostname = extractSelfHostname(from: options.effectiveBaseUrl.absoluteString)

        options.debugLogger(.sdkConfigured, [
            "platform": device.platform,
            "sdk_version": SDK.version,
        ])

        // ALWAYS install the manual error-capture routing closure so
        // cd.captureError(...) works on every project. The OS-level
        // NSSetUncaughtExceptionHandler is gated separately inside
        // installErrorCapture via the captureUncaughtExceptions option,
        // so consumers who prefer Crashlytics / Sentry as their primary
        // global handler can still receive manual captures from
        // do/catch blocks without our global hook in the chain.
        installErrorCapture()

        installLifecycleObservers()

        // Try a flush on start to ship anything rehydrated from
        // the prior session. Fire-and-forget — if there's nothing
        // to send, this is a no-op.
        Task { await queue.flush() }

        // Boot heartbeat. POSTs /sdk/heartbeat so the dashboard's
        // onboarding checklist flips LIVE within ~200ms — same shape
        // and timing as Web/Node/RN. Fire-and-forget; failure is
        // surfaced via the debug logger. Skipped automatically when
        // `captureUncaughtExceptions: false` AND we're in a test
        // build via the urlSession injection (URLProtocol stub).
        Task { _ = await self.heartbeat() }

        // ---- Auto-tracking & ambient signal modules ----
        //
        // These run in the SAME process-singleton fashion the
        // Web/Node/RN SDKs do — sessions, screen views, taps, perf
        // vitals, network-edge flush, and StoreKit transactions all
        // flow into the same track() pipeline as developer-fired
        // events. Each module is independently opt-out via
        // `CrossdeckOptions` flags.

        // 1. AutoTracker — sessions / screens / taps. Multicast
        //    registration so multiple Crossdeck instances (test
        //    harnesses, hot-reload) share the global swizzles.
        let weakSelf: @Sendable (String, [String: Any]) -> Void = { [weak self] name, props in
            self?.track(name, properties: props)
        }
        autoTrackUnregister = AutoTracker.shared.register(
            config: options.autoTrack,
            emit: weakSelf
        )

        // 2. Reachability — flush on offline→online edge.
        if options.enableReachabilityFlush {
            if #available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *) {
                let queueRef = queue
                let reach = Reachability(onReachable: {
                    Task { await queueRef.flush() }
                })
                reach.start()
                self.reachability = reach
            }
        }

        // 3. MetricKit perf vitals — daily aggregates + near-real-
        //    time diagnostics.
        #if canImport(MetricKit) && !os(watchOS) && !os(tvOS)
        if options.enablePerformanceMonitoring {
            if #available(iOS 14.0, macOS 12.0, *) {
                let perf = PerformanceVitals(emit: weakSelf)
                perf.start()
                self.performanceVitals = perf
            }
        }
        #endif

        // 4. StoreKit 2 Transaction.updates auto-listener.
        #if canImport(StoreKit) && os(iOS)
        if options.automaticPurchaseTracking {
            if #available(iOS 15.0, *) {
                let httpRef = http
                let debugLogger = options.debugLogger
                let purchaseTracker = PurchaseAutoTrack(
                    emitTrack: weakSelf,
                    syncBackend: { jws, originalTransactionId in
                        // Same backend endpoint syncPurchases() uses
                        // — single contract surface. Build the same
                        // PurchaseSyncRequest payload so server-side
                        // parsing is identical between manual and
                        // automatic paths.
                        let body = PurchaseSyncRequest(
                            rail: "apple",
                            signedTransactionInfo: jws,
                            signedRenewalInfo: nil,
                            appAccountToken: originalTransactionId
                        )
                        guard let bodyData = try? JSONEncoder().encode(body) else { return }
                        let outcome = await httpRef.request(
                            method: "POST",
                            path: "/purchases/sync",
                            body: bodyData,
                            idempotencyKey: "auto_purch_" + UUID().uuidString
                                .lowercased()
                                .replacingOccurrences(of: "-", with: "")
                        )
                        if outcome.kind != .success {
                            debugLogger(.sdkConfigured, [
                                "auto_purchase_sync_failed": String(describing: outcome.error),
                            ])
                        }
                    }
                )
                purchaseTracker.start()
                self.purchaseAutoTrack = purchaseTracker
            }
        }
        #endif
    }

    // MARK: - Public API

    /// Track a domain-specific event. Fire-and-forget; never throws.
    ///
    /// Validation behaviour:
    ///   * Empty `name` is dropped with a debug log + an
    ///     `assertionFailure` (loud in Debug builds, silent no-op
    ///     in Release). Aligns with how Apple's first-party SDKs
    ///     and every major analytics SDK (Mixpanel, Amplitude,
    ///     Sentry, Firebase Analytics) shape their iOS surface —
    ///     a typo'd event name should never propagate up the call
    ///     stack and crash a customer's app.
    ///   * Property values are sanitised in-place (NaN → null,
    ///     strings > 1024 chars truncated, cyclic graphs replaced,
    ///     etc.) with debug warnings. Never throws on a property.
    ///   * Called after `stop()` → debug log + no-op.
    ///
    /// Cross-SDK contract: Web/Node/RN's `track()` throw in JavaScript
    /// where uncaught throws propagate to the global error handler.
    /// Swift's compile-time enforcement makes that pattern hostile —
    /// every call site has to wrap in `try?`. The validation INTENT
    /// is identical; only the signalling mechanism is Swift-idiomatic.
    public func track(_ name: String, properties: [String: Any]? = nil) {
        guard isStarted() else {
            options.debugLogger(.sdkConfigured, ["track_dropped": "not_initialized", "event": name])
            return
        }
        guard !name.isEmpty else {
            assertionFailure("[Crossdeck] track(name:) requires a non-empty name. Event dropped.")
            options.debugLogger(.sdkConfigured, ["track_dropped": "missing_event_name"])
            return
        }
        // Sanitise + warn (NEVER throws — matches Web/Node/RN
        // bank-grade contract that track() never fails on a single
        // bad property). The cleaned bag ships on the wire; warnings
        // surface via the debug logger for visibility.
        let sanitisedProperties: [String: Any]
        if let properties {
            let result = validateEventProperties(properties)
            sanitisedProperties = result.properties
            for warning in result.warnings {
                options.debugLogger(.sdkPropertyCoerced, [
                    "key": warning.key,
                    "kind": warning.kind.rawValue,
                ])
            }
        } else {
            sanitisedProperties = [:]
        }

        // SNAPSHOT all SDK state synchronously on the caller's thread
        // BEFORE the Task. This eliminates the classic identify+track
        // race where the Task would read identity AFTER a concurrent
        // identify Task updated it — meaning a track call following
        // identify could observe either the pre- or post-identify
        // developerUserId depending on scheduler luck. With sync
        // snapshot, the developerUserId baked into the wire event is
        // exactly what was visible at the moment track() returned to
        // the caller.
        let consentSnapshot = consent.snapshotSync()
        guard consentSnapshot.consent.analytics else {
            options.debugLogger(.sdkConsentDenied, ["event": name])
            return
        }

        // Warn (don't block) on property names that look like PII or
        // secrets — `email`, `password`, `token`, `secret`, `card`,
        // `phone`, or any name containing `password` / `credit_card`.
        // Same patterns as Web/Node/RN — cross-platform teams get
        // identical warnings.
        let sensitiveHits = findSensitivePropertyKeys(properties)
        if !sensitiveHits.isEmpty {
            options.debugLogger(.sdkSensitivePropertyWarning, [
                "event": name,
                "keys": sensitiveHits.joined(separator: ","),
            ])
        }
        let scrub = consentSnapshot.scrub
        let identitySnapshot = identity.snapshotSync()
        let superPropsSnapshot = superProperties.snapshotSync()
        // Capture sessionId from the AutoTracker so every event
        // tracks its session anchor — same enrichment Web SDK does
        // via `state.autoTracker.currentSessionId`. Empty when
        // sessions auto-track is off; consumers can still
        // hand-supply via super-properties.
        let sessionId = AutoTracker.shared.currentSessionId()

        // Convert caller-supplied properties to Sendable AnyCodable
        // immediately so the Task closure captures only Sendable
        // values (and so a caller mutating the dict after track()
        // returns can't poison the queued event).
        // Convert the SANITISED properties (post-coercion) to
        // Sendable AnyCodable for the Task closure. The original
        // caller-passed bag is discarded — the sanitiser already
        // returned a cleaned copy with non-encodable values
        // dropped / coerced.
        var codedProperties: [String: AnyCodable] = [:]
        for (k, v) in sanitisedProperties { codedProperties[k] = AnyCodable(v) }
        let codedSnapshot = codedProperties
        let devicePayload = device.asPayload

        Task {
            var merged: [String: Any] = [:]
            for (k, v) in superPropsSnapshot { merged[k] = v }
            for (k, v) in devicePayload { merged[k] = v }
            for (k, v) in codedSnapshot { merged[k] = v.value }
            // Add sessionId LAST so the auto-track anchor wins over
            // any caller-supplied "sessionId" key. Skip when no
            // session is active (rare — only happens between
            // background-end and next-foreground or when sessions
            // auto-track is disabled).
            if let sessionId { merged["sessionId"] = sessionId }

            let final = scrub ? (scrubPIIDeep(merged) as? [String: Any]) ?? merged : merged
            var coded: [String: AnyCodable] = [:]
            for (k, v) in final { coded[k] = AnyCodable(v) }

            let event = WireEvent(
                id: "evt_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                name: name,
                timestamp: Date(),
                properties: coded,
                anonymousId: identitySnapshot.anonymousId,
                developerUserId: identitySnapshot.developerUserId,
                crossdeckCustomerId: identitySnapshot.crossdeckCustomerId
            )

            await queue.enqueue(event)
            await breadcrumbs.add(Breadcrumb(
                category: .custom,
                level: .info,
                message: "track \(name)"
            ))
        }
    }

    /// Link the device to a stable user identity.
    ///
    /// **Vocabulary contract (matches Web/Node/RN exactly):**
    /// - `userId` — your auth provider's stable user identifier
    ///   (Firebase Auth's `uid`, Auth0's `sub`, Supabase's `id`,
    ///   etc.). NEVER pass a `cdcust_…` here — that's a separate
    ///   server-side handle.
    /// - `email` — first-class, top-level. The platform-wide
    ///   universal anchor for identity-merge: passing email here
    ///   lets the backend coalesce the same person across devices
    ///   even if their `userId` changes (rare but happens after
    ///   auth-provider migrations).
    /// - `traits` — arbitrary profile data, sanitised at the SDK
    ///   boundary. Examples: `name`, `plan`, `signedUpAt`. Never
    ///   put PII like email here — use the dedicated parameter.
    ///
    /// **Side effects.**
    /// - The entitlement cache is unconditionally cleared so a
    ///   freshly-identified user never observes the prior user's
    ///   entitlements through any sync read path.
    /// - An `$identify` event is queued carrying the email + traits
    ///   if either is supplied, so the same downstream consumers
    ///   that handle `track` events also see the identify.
    ///
    /// Throws `CrossdeckError` if `userId` is empty or if any
    /// trait value isn't JSON-encodable.
    /// Link the device to a stable user identity. Fire-and-forget;
    /// never throws. Same Swift-idiomatic non-throwing shape as
    /// `track()` — see that method's doc for the cross-SDK rationale.
    ///
    /// Validation behaviour:
    ///   * Empty `userId` is dropped with a debug log + an
    ///     `assertionFailure` (loud in Debug, silent in Release).
    ///   * Trait values are sanitised; never throws on a trait.
    ///   * Called after `stop()` → debug log + no-op.
    ///
    /// For the throwing variant that awaits the canonical
    /// `crossdeckCustomerId`, see `identifyAndWait(...)`.
    public func identify(
        userId: String,
        email: String? = nil,
        traits: [String: Any]? = nil
    ) {
        guard isStarted() else {
            options.debugLogger(.sdkConfigured, ["identify_dropped": "not_initialized"])
            return
        }
        guard !userId.isEmpty else {
            assertionFailure("[Crossdeck] identify(userId:) requires a non-empty userId. Identify dropped.")
            options.debugLogger(.sdkConfigured, ["identify_dropped": "missing_user_id"])
            return
        }
        // Sanitise traits — non-encodable / oversize / cyclic values
        // are coerced or dropped (matches Web/Node/RN). Never throws.
        let cleanedTraits: [String: Any]
        if let traits {
            let result = validateEventProperties(traits)
            cleanedTraits = result.properties
            for warning in result.warnings {
                options.debugLogger(.sdkPropertyCoerced, [
                    "scope": "identify.traits",
                    "key": warning.key,
                    "kind": warning.kind.rawValue,
                ])
            }
        } else {
            cleanedTraits = [:]
        }

        // SYNC mutations: set the developerUserId AND wipe the
        // entitlement cache before this method returns. Two reasons:
        //
        //   1) A subsequent track() (or the `$identify` event below)
        //      MUST observe the new developerUserId — async ordering
        //      between two Tasks would leave the visible identity
        //      undefined for a moment.
        //   2) Unconditional cache clear is part of the bank-grade
        //      contract documented for KPMG audit: a freshly
        //      identified user MUST NOT briefly observe the prior
        //      user's entitlements through any sync read path.
        //      Even identifying with the same id wipes the cache —
        //      a tiny redundant rebuild is cheaper than a leak.
        identity.setDeveloperUserIdSync(userId)
        entitlements.clearSync()
        options.debugLogger(.sdkConfigured, ["user_id": userId])

        // Breadcrumb add is async (Breadcrumbs is an actor); fire
        // and forget — this is observability, not on the data-
        // integrity path.
        let breadcrumbsRef = breadcrumbs
        Task {
            await breadcrumbsRef.add(Breadcrumb(
                category: .identity,
                level: .info,
                message: "identify \(userId)"
            ))
        }

        // Fire the server-side alias call in the background. Matches
        // Web/Node/RN: POSTs /identity/alias with userId + anonymousId
        // + email + traits; on success persists the returned cdcust_;
        // on failure surfaces a warning to the debug logger without
        // throwing (local identity is already correct via the sync
        // setter above — server-side merge is best-effort).
        let snapshot = identity.snapshotSync()
        let appIdValue = options.appId
        let envValue = options.environment.rawValue
        // Traits to wire format: stringify every value (the wire
        // shape is Dictionary<String, String>; complex types get
        // String(describing:) — a degenerate trait that's not a
        // string round-trips as its description rather than
        // crashing the JSON encoder).
        let wireTraits: [String: String] = cleanedTraits.reduce(into: [String: String]()) { acc, kv in
            if let s = kv.value as? String {
                acc[kv.key] = s
            } else {
                acc[kv.key] = String(describing: kv.value)
            }
        }
        let httpRef = http
        let identityRef = identity
        let debug = options.debugLogger
        Task {
            do {
                let result = try await Crossdeck.postAliasIdentity(
                    http: httpRef,
                    body: AliasIdentityRequest(
                        userId: userId,
                        anonymousId: snapshot.anonymousId,
                        email: email,
                        traits: wireTraits
                    )
                )
                // Persist the canonical cdcust_ so subsequent events
                // ship it on the wire and a sign-out / sign-in cycle
                // can short-circuit a redundant alias call.
                identityRef.setCrossdeckCustomerIdSync(result.crossdeckCustomerId)
                debug(.sdkConfigured, [
                    "alias": "ok",
                    "cdcust": result.crossdeckCustomerId,
                    "merge_pending": String(result.mergePending),
                ])
            } catch {
                // Best-effort. Local identity is already set; server
                // merge will catch up on the next identify or on a
                // backend reconciliation pass.
                debug(.sdkInvalidKey, [
                    "alias": "failed",
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// Manually trigger a `/identity/alias` round-trip and await the
    /// canonical cdcust_ result. The synchronous `identify(userId:)`
    /// already fires this in the background — only use the async
    /// variant when you need to know the cdcust_ before continuing
    /// (e.g. server-side cross-reference at sign-in).
    public func identifyAndWait(
        userId: String,
        email: String? = nil,
        traits: [String: Any]? = nil
    ) async throws -> AliasResult {
        try assertStarted()
        guard !userId.isEmpty else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "missing_user_id",
                message: "identifyAndWait(userId:) requires a non-empty userId."
            )
        }
        // Drive the sync side-effects (local identity set, entitlement
        // cache clear, breadcrumb, background alias) through the same
        // path as the non-throwing identify().
        identify(userId: userId, email: email, traits: traits)
        let snapshot = identity.snapshotSync()
        // Re-sanitise traits for this call's wire body — the prior
        // identify() did the same on its own background Task; doing
        // it here keeps the wireTraits in sync with whatever Web/RN
        // would ship.
        let cleanedTraitsForWait: [String: Any] = traits.map { validateEventProperties($0).properties } ?? [:]
        let wireTraits: [String: String] = cleanedTraitsForWait.reduce(into: [String: String]()) { acc, kv in
            if let s = kv.value as? String { acc[kv.key] = s } else { acc[kv.key] = String(describing: kv.value) }
        }
        let result = try await Crossdeck.postAliasIdentity(
            http: http,
            body: AliasIdentityRequest(
                userId: userId,
                anonymousId: snapshot.anonymousId,
                email: email,
                traits: wireTraits
            )
        )
        identity.setCrossdeckCustomerIdSync(result.crossdeckCustomerId)
        return result
    }

    /// GDPR right-to-be-forgotten — POSTs `/identity/forget` and
    /// then ALWAYS runs the local cleanup, even on server error.
    ///
    /// Why local wipe runs regardless of server outcome: the
    /// publishable-key `forget` flow may return 401 from the
    /// backend if the call is identified (cd_pub_ + identified
    /// erasure requires `idToken`, which v1.0.1 doesn't yet
    /// support). Matches Web SDK behaviour (sdks/web/src/crossdeck.ts:809)
    /// — local state wipes anyway so the consumer's GDPR contract
    /// holds even when the server-side erasure needs a follow-up
    /// from their own backend with the secret key.
    ///
    /// Throws on outright network failure so the caller can show
    /// "couldn't reach Crossdeck — try again" UI; local wipe still
    /// completes in the throw path.
    public func forget() async throws {
        try assertStarted()
        let snap = identity.snapshotSync()
        let body = ForgetIdentityRequest(
            userId: snap.developerUserId,
            anonymousId: snap.anonymousId,
            customerId: snap.crossdeckCustomerId
        )
        let bodyData = try JSONEncoder().encode(body)
        let outcome = await http.request(
            method: "POST",
            path: "/identity/forget",
            body: bodyData,
            idempotencyKey: "batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        )

        // Local wipe FIRST — runs regardless of server outcome so a
        // server-side 401 (publishable-key identified erasure
        // restriction) doesn't leave stale identity on the device.
        await identity.reset()
        await entitlements.clear()
        await superProperties.clear()
        await breadcrumbs.clear()

        // If the server actually rejected the request, surface that
        // to the caller — but local state is already clean. The
        // consumer can retry later (e.g. from their backend with a
        // secret key) without worrying about double-erasing locally.
        if outcome.kind != .success {
            // 401 from publishable-key identified erasure is the
            // documented carve-out — log it but don't throw.
            if outcome.envelope?.statusCode == 401 {
                options.debugLogger(.sdkInvalidKey, [
                    "endpoint": "/identity/forget",
                    "hint": "Server requires idToken for identified erasure with cd_pub_; local state is wiped, retry server-side with cd_sk_.",
                ])
                return
            }
            throw outcome.error ?? CrossdeckError(
                type: .apiError,
                code: "forget_failed",
                message: "/identity/forget did not succeed. Local state already wiped — server retry needed."
            )
        }
    }

    /// Forward purchase evidence to the backend for verification +
    /// entitlement projection. iOS apps wire this from StoreKit 2
    /// transaction callbacks; the backend validates the JWS
    /// signature, projects the entitlement set, and returns it so
    /// the local cache warms immediately.
    public func syncPurchases(
        rail: AuditRail,
        signedTransactionInfo: String? = nil,
        signedRenewalInfo: String? = nil,
        appAccountToken: String? = nil
    ) async throws -> PurchaseResult {
        try assertStarted()
        // v1.0.1: rail must be `.apple`. Backend rejects rail=google
        // explicitly with `google_not_supported` (backend/src/api/
        // v1-purchases-validation.ts:27). Google Play wiring ships
        // in v1.1 alongside the React Native + Android Play Billing
        // surface. Catch early so the consumer sees a clear error.
        guard rail == .apple else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "rail_not_supported",
                message: "syncPurchases v1.0.1 supports rail=apple only. Google Play support ships in v1.1."
            )
        }
        // Snapshot identity for the post-sync cache warm — we
        // dropped the wire-body identity hints (server derives them
        // from the JWS), but we still need the developerUserId
        // locally to key the entitlement cache.
        let snap = identity.snapshotSync()
        let body = PurchaseSyncRequest(
            rail: rail.rawValue,
            signedTransactionInfo: signedTransactionInfo,
            signedRenewalInfo: signedRenewalInfo,
            appAccountToken: appAccountToken
        )
        let bodyData = try JSONEncoder().encode(body)
        let outcome = await http.request(
            method: "POST",
            path: "/purchases/sync",
            body: bodyData,
            idempotencyKey: "batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        )
        guard outcome.kind == .success,
              let data = outcome.envelope?.body else {
            throw outcome.error ?? CrossdeckError(
                type: .apiError,
                code: "sync_purchases_failed",
                message: "/purchases/sync did not succeed."
            )
        }
        let result = try JSONDecoder().decode(PurchaseResult.self, from: data)
        // Warm the cache with the projected entitlement set.
        identity.setCrossdeckCustomerIdSync(result.crossdeckCustomerId)
        if let userId = snap.developerUserId {
            await entitlements.write(EntitlementSnapshot(
                developerUserId: userId,
                entitlements: result.entitlements
            ))
        }
        return result
    }

    /// Fetch the current entitlement set from the server and hydrate
    /// the local cache. Returns the freshly-fetched set so the
    /// caller can render UI immediately without re-reading from
    /// `entitlementsForCurrentCustomer()`.
    ///
    /// On a 5xx / network failure, the cache is preserved
    /// (last-known-good wins) and the failure is recorded via
    /// `markRefreshFailed` so `freshness()` surfaces it to UI.
    @discardableResult
    public func getEntitlements() async throws -> [PublicEntitlement] {
        try assertStarted()
        let snap = identity.snapshotSync()
        guard let userId = snap.developerUserId else {
            throw CrossdeckError(
                type: .invalidRequest,
                code: "no_identity",
                message: "getEntitlements requires identify(userId:) to have been called first."
            )
        }
        // Backend requires one of customerId / userId / anonymousId
        // (backend/src/api/v1-entitlements.ts:92). Send every axis
        // we know — server picks the most specific.
        var query: [String: String] = ["userId": userId]
        if let cdcust = snap.crossdeckCustomerId { query["customerId"] = cdcust }
        query["anonymousId"] = snap.anonymousId
        let outcome = await http.request(method: "GET", path: "/entitlements", query: query)
        guard outcome.kind == .success, let data = outcome.envelope?.body else {
            // Bank-grade: don't fail the cache down to free. Mark
            // the refresh as failed; UI can show a "checking…" badge
            // but a paying customer keeps their entitlement.
            await entitlements.markRefreshFailed()
            throw outcome.error ?? CrossdeckError(
                type: .apiError,
                code: "get_entitlements_failed",
                message: "/entitlements did not succeed."
            )
        }
        let response = try JSONDecoder().decode(EntitlementsListResponse.self, from: data)
        identity.setCrossdeckCustomerIdSync(response.crossdeckCustomerId)
        await entitlements.write(EntitlementSnapshot(
            developerUserId: userId,
            entitlements: response.data
        ))
        return response.data
    }

    /// Subscribe to entitlement-cache mutations. Returns a token;
    /// retain it in your view model and pass back to
    /// `unsubscribeFromEntitlements(_:)` to detach.
    @discardableResult
    public func onEntitlementsChange(
        _ handler: @escaping EntitlementSubscriber
    ) async -> UUID {
        return await entitlements.subscribe(handler)
    }

    public func unsubscribeFromEntitlements(_ token: UUID) async {
        await entitlements.unsubscribe(token)
    }

    /// Boot heartbeat. POSTs `/sdk/heartbeat` to flip the dashboard
    /// onboarding checklist to LIVE within ~200ms and to capture
    /// server-time for clock-skew detection. Fires automatically on
    /// `start(...)` unless `autoHeartbeat: false`.
    @discardableResult
    public func heartbeat() async -> HeartbeatResponse? {
        // GET — matches the backend route (backend/src/api/v1.ts:252).
        // The handler reads appId + environment from the API key
        // (resolveAppKey), NOT the request body. Body would be
        // silently dropped + previously the SDK was POSTing → 404.
        // The Crossdeck-Sdk-Version header (set in HTTPClient) is
        // what populates the per-SDK dashboard surface tile.
        let outcome = await http.request(
            method: "GET",
            path: "/sdk/heartbeat"
        )
        guard outcome.kind == .success, let data = outcome.envelope?.body else { return nil }
        return try? JSONDecoder().decode(HeartbeatResponse.self, from: data)
    }

    /// Internal helper for the alias POST. Throws on any non-success
    /// outcome; decodes the AliasResult body on success.
    private static func postAliasIdentity(
        http: HTTPClient,
        body: AliasIdentityRequest
    ) async throws -> AliasResult {
        let bodyData = try JSONEncoder().encode(body)
        let outcome = await http.request(
            method: "POST",
            path: "/identity/alias",
            body: bodyData,
            idempotencyKey: "batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        )
        guard outcome.kind == .success, let data = outcome.envelope?.body else {
            throw outcome.error ?? CrossdeckError(
                type: .apiError,
                code: "alias_failed",
                message: "/identity/alias did not succeed."
            )
        }
        return try JSONDecoder().decode(AliasResult.self, from: data)
    }

    /// Synchronous check — returns true iff the entitlement key is
    /// in the cached set for the currently identified user. Safe
    /// to call from any thread, including SwiftUI view bodies and
    /// UIKit tap handlers. Never blocks on network.
    ///
    /// Returns false if no user is identified, or if the cache has
    /// nothing for the current user (treat as "not yet known" —
    /// fall back to a refresh + paywall if needed).
    public func isEntitled(_ key: String) -> Bool {
        guard let userId = identity.snapshotSync().developerUserId else { return false }
        return entitlements.isEntitledSync(key, for: userId)
    }

    /// Synchronous read of the full entitlement set for the current
    /// user. Returns nil if no user is identified or the cache is
    /// cold for them. Filters out expired entitlements (validUntil
    /// in the past).
    public func entitlementsForCurrentCustomer() -> [PublicEntitlement]? {
        guard let userId = identity.snapshotSync().developerUserId else { return nil }
        return entitlements.entitlementsSync(for: userId)
    }

    /// Same as `entitlementsForCurrentCustomer` but returns just the
    /// active entitlement keys — convenient for paywall UIs that
    /// only need to render the set of unlocked features.
    public func activeEntitlementKeys() -> [String]? {
        return entitlementsForCurrentCustomer()?.map { $0.key }
    }

    /// Sign-out path. Wipes the local identity, entitlement cache,
    /// super-properties, and breadcrumbs; regenerates the anonymous
    /// ID so the next anonymous session is fully unlinked from the
    /// prior identified user.
    ///
    /// Fire-and-forget; never throws. Same Swift-idiomatic shape as
    /// `track()` and `identify()`. Called after `stop()` → debug log
    /// + no-op.
    public func reset() {
        guard isStarted() else {
            options.debugLogger(.sdkConfigured, ["reset_dropped": "not_initialized"])
            return
        }
        Task {
            await identity.reset()
            await entitlements.clear()
            await superProperties.clear()
            await breadcrumbs.clear()
            options.debugLogger(.sdkConfigured, [:])
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

    /// Capture a handled message (no underlying Error). Used for
    /// "this shouldn't have happened" log lines you want to land in
    /// the dashboard. Goes through the same pipeline as
    /// `captureError`, but with no stack and no `Error` type.
    /// Mirrors Web/Node/RN.
    public func captureMessage(_ message: String, level: BreadcrumbLevel = .info) {
        let synthetic = CrossdeckError(
            type: .unknown,
            code: "captured_message",
            message: message
        )
        ErrorCapture.shared.captureError(synthetic, handled: true)
        // Also drop a breadcrumb so a subsequent error has the
        // captured message in its context window.
        let crumbsRef = breadcrumbs
        Task {
            await crumbsRef.add(Breadcrumb(
                category: .custom,
                level: level,
                message: message
            ))
        }
    }

    /// Set a single tag — key/value pair attached to every
    /// subsequent error event until cleared or overwritten. Tags
    /// are first-class Sentry-style search facets (`tag:plan=pro`
    /// in the dashboard). Persisted in-memory for the lifetime of
    /// the Crossdeck instance.
    public func setTag(_ key: String, _ value: String) {
        guard !key.isEmpty else { return }
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        errorTags[key] = value
    }

    /// Bulk tag setter — replaces the entire tag map atomically.
    /// Pass `[:]` to clear all tags.
    public func setTags(_ tags: [String: String]) {
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        errorTags = tags
    }

    /// Set a context block (Sentry-style). Each block is a named
    /// dictionary attached to error events — e.g.
    /// `setContext("device", ["build": "2.3.1", "store": "appstore"])`.
    /// Pass `[:]` to clear a block.
    public func setContext(_ name: String, _ data: [String: String]) {
        guard !name.isEmpty else { return }
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        if data.isEmpty {
            errorContext.removeValue(forKey: name)
        } else {
            errorContext[name] = data
        }
    }

    /// Replace the `beforeSendError` hook at runtime. The hook
    /// installed via `CrossdeckOptions.beforeSendError` is the
    /// initial value; this method lets a consumer rotate it after
    /// `start(...)` (e.g. install a stricter filter once consent
    /// changes). Pass `nil` to remove the hook.
    public func setErrorBeforeSend(_ handler: BeforeSendErrorHandler?) {
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        runtimeBeforeSend = handler
    }

    /// Internal snapshot of runtime error state — used by the
    /// ErrorCapture install closure when building a wire event.
    func snapshotErrorState() -> (
        tags: [String: String],
        context: [String: [String: String]],
        beforeSend: BeforeSendErrorHandler?
    ) {
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        return (errorTags, errorContext, runtimeBeforeSend)
    }

    public func setConsent(_ state: ConsentState) {
        Task {
            await consent.update(state)
            options.debugLogger(.sdkConsentChanged, [
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
                code: "not_initialized",
                message: "Crossdeck client was stopped — call Crossdeck.start(...) again."
            )
        }
    }

    /// Non-throwing variant of `assertStarted()` used by the fire-and-
    /// forget public API (track / identify / reset). Returns false
    /// after `stop()` so callers can early-return without inflicting
    /// a thrown error on every call site.
    private func isStarted() -> Bool {
        startedLock.lock()
        defer { startedLock.unlock() }
        return started
    }

    public func stop() {
        startedLock.lock()
        defer { startedLock.unlock() }
        started = false
        options.debugLogger(.sdkConfigured, [:])

        // Tear down auto-track listener + ambient signal modules.
        // The AutoTracker singleton's global swizzles + lifecycle
        // observers STAY installed (un-swizzling is race-prone and
        // re-installing on a new start() would lose the dispatch-
        // once guarantee). But our emit closure unregisters so no
        // more events flow to THIS client.
        autoTrackUnregister?()
        autoTrackUnregister = nil

        if #available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *),
           let reach = reachability as? Reachability {
            reach.stop()
        }
        reachability = nil

        #if canImport(MetricKit) && !os(watchOS) && !os(tvOS)
        if #available(iOS 14.0, macOS 12.0, *),
           let perf = performanceVitals as? PerformanceVitals {
            perf.stop()
        }
        #endif
        performanceVitals = nil

        #if canImport(StoreKit) && os(iOS)
        if #available(iOS 15.0, *),
           let tracker = purchaseAutoTrack as? PurchaseAutoTrack {
            tracker.stop()
        }
        #endif
        purchaseAutoTrack = nil

        // Best-effort: persist anything in flight before relinquishing.
        Task { await queue.persistAll() }
        // Clear the process-singleton iff THIS instance is the one
        // currently published. If a newer client was already started
        // (e.g. test teardown sequence), don't clobber its slot.
        Crossdeck.currentLock.lock()
        if Crossdeck._current === self {
            Crossdeck._current = nil
        }
        Crossdeck.currentLock.unlock()
    }

    private func installErrorCapture() {
        let breadcrumbsRef = breadcrumbs
        let queueRef = queue
        let identityRef = identity
        let consentRef = consent
        let debugLogger = options.debugLogger
        // Seed the runtime beforeSend with the option-provided hook
        // so a consumer's CrossdeckOptions.beforeSendError is the
        // initial value of the runtime-replaceable hook. Subsequent
        // setErrorBeforeSend(...) calls replace it; the capture
        // closure reads through errorStateRef() each event so the
        // replacement takes effect for the NEXT error.
        if let initialBeforeSend = options.beforeSendError {
            setErrorBeforeSend(initialBeforeSend)
        }
        // Sendable @escaping read-through into the runtime error
        // state (tags, context, beforeSend). Captured by reference
        // so post-install setTag / setContext / setErrorBeforeSend
        // calls take effect for the NEXT error.
        let errorStateRef: @Sendable () -> (
            tags: [String: String],
            context: [String: [String: String]],
            beforeSend: BeforeSendErrorHandler?
        ) = { [weak self] in
            self?.snapshotErrorState() ?? ([:], [:], nil)
        }

        ErrorCapture.shared.install(
            beforeSend: nil, // runtime hook applied inside capture closure

            breadcrumbs: { await breadcrumbsRef.snapshot() },
            selfHostname: selfHostname,
            capture: { event in
                // Errors-consent gate. Sync read from the consent
                // box so we don't pay an actor hop per error. If
                // consent.errors is false, drop the event silently
                // (consumers who want crash reports regardless
                // should leave consent.errors true even when
                // analytics is off — they're independent toggles).
                let consentSnapshot = consentRef.snapshotSync()
                guard consentSnapshot.consent.errors else {
                    debugLogger(.sdkConsentDenied, [
                        "channel": "errors",
                        "type": event.type,
                    ])
                    return
                }

                // Identity snapshot is sync — the error path
                // must ship sub-second under crash conditions,
                // never block on an actor hop.
                let identitySnapshot = identityRef.snapshotSync()

                // Build the wire payload. EVERY string field that
                // could carry user data (message, stack symbols,
                // breadcrumb messages + data) is run through the
                // PII scrubber when scrub is enabled.
                let scrub = consentSnapshot.scrub
                let scrubbedMessage = scrub ? scrubPII(event.message) : event.message
                let stackStrings: [String] = event.stack.map {
                    let raw = "\($0.module):\($0.symbol)"
                    return scrub ? scrubPII(raw) : raw
                }

                var props: [String: AnyCodable] = [
                    "error.type": AnyCodable(event.type),
                    "error.message": AnyCodable(scrubbedMessage),
                    "error.fingerprint": AnyCodable(event.fingerprint),
                    "error.handled": AnyCodable(event.handled),
                    "error.timestamp_ms": AnyCodable(Int(event.timestamp.timeIntervalSince1970 * 1000)),
                ]

                // Runtime tags + context (from setTag / setContext)
                // attach to every error event. Mirrors Web/Node/RN
                // — the dashboard surfaces these as search facets.
                let errorState = errorStateRef()
                if !errorState.tags.isEmpty {
                    props["error.tags"] = AnyCodable(errorState.tags)
                }
                if !errorState.context.isEmpty {
                    props["error.context"] = AnyCodable(errorState.context)
                }
                if !stackStrings.isEmpty {
                    props["error.stack"] = AnyCodable(stackStrings)
                }
                if !event.breadcrumbs.isEmpty {
                    // Breadcrumbs ship as an array of [String: Any]
                    // dicts — one per crumb — so the dashboard can
                    // render them as a timeline ordered alongside
                    // the error. Each crumb's `message` + `data`
                    // values are scrubbed.
                    let crumbs: [[String: Any]] = event.breadcrumbs.map { crumb in
                        var dict: [String: Any] = [
                            "timestamp_ms": Int(crumb.timestamp.timeIntervalSince1970 * 1000),
                            "category": crumb.category.rawValue,
                            "level": crumb.level.rawValue,
                            "message": scrub ? scrubPII(crumb.message) : crumb.message,
                        ]
                        if let data = crumb.data, !data.isEmpty {
                            let scrubbedData = data.mapValues { scrub ? scrubPII($0) : $0 }
                            dict["data"] = scrubbedData
                        }
                        return dict
                    }
                    props["error.breadcrumbs"] = AnyCodable(crumbs)
                }

                // Apply runtime beforeSend hook (replaceable via
                // setErrorBeforeSend). Returning nil from the hook
                // drops the event. Matches Web/Node/RN semantics.
                if let hook = errorState.beforeSend {
                    guard hook(event) != nil else {
                        debugLogger(.sdkConsentDenied, [
                            "channel": "errors",
                            "reason": "beforeSend_returned_nil",
                        ])
                        return
                    }
                }

                let wire = WireEvent(
                    id: "err_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                    name: "$error",
                    timestamp: event.timestamp,
                    properties: props,
                    anonymousId: identitySnapshot.anonymousId,
                    developerUserId: identitySnapshot.developerUserId,
                    crossdeckCustomerId: identitySnapshot.crossdeckCustomerId
                )

                // Enqueue is async (queue is an actor); we hand
                // off via Task here, which is the same pattern the
                // track() pipeline uses.
                Task { await queueRef.enqueue(wire) }
            },
            installGlobalHandler: options.captureUncaughtExceptions
        )
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default

        #if canImport(UIKit) && !os(watchOS)
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
        // willTerminate fires on user force-quit from the app switcher.
        // Without this observer, up to one batch of queued events
        // is lost. Sync persist (vs flush) is the contract here —
        // we want the events on disk before the process dies; the
        // next launch's queue rehydration ships them.
        center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.persistAll() }
        }
        #elseif canImport(AppKit)
        // Pure AppKit Mac apps land here (Mac Catalyst lands in
        // the UIKit branch above). Cover Cmd+Q + Cmd+H + system
        // shutdown so a Mac customer's queued events don't vanish
        // when the user closes the app.
        center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.persistAll() }
        }
        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.persistAll() }
        }
        #elseif canImport(WatchKit) && os(watchOS)
        // watchOS — extension-level lifecycle. WKExtension.shared
        // emits applicationWillResignActive when the user lowers
        // their wrist, applicationDidEnterBackground when the watch
        // face takes over.
        center.addObserver(
            forName: WKExtension.applicationWillResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.persistAll() }
        }
        center.addObserver(
            forName: WKExtension.applicationDidEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.queue.flush() }
        }
        #endif
    }
}
