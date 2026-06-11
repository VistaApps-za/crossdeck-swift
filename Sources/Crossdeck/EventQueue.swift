// Event queue — the heart of the SDK.
//
// Single, actor-isolated owner of the buffered + in-flight + on-disk
// event state. Responsibilities, in order of importance to data
// integrity:
//
//  1) NEVER LOSE A BUFFERED EVENT. From the moment `enqueue` returns
//     to the moment ingest confirms the batch, the event lives in
//     either the in-memory buffer, the pending-batch slot, or the
//     on-disk durability layer — never zero of these.
//
//  2) NEVER DOUBLE-INSERT. Each batch has a stable `idempotencyKey`
//     generated once on first send. Server-side dedup uses this
//     key, so retries of the same batch are coalesced.
//
//  3) 4xx HARD STOP. A permanent 4xx (auth invalid, payload broken)
//     drains the batch into the `onPermanentFailure` callback and
//     does NOT retry — the same payload will fail forever, and
//     retrying it forever both wastes battery and (worse) keeps
//     blocking newer events behind the dead batch.
//
// The `pendingBatch` slot is the critical invariant. On flush
// start, we MOVE the head-of-queue into `pendingBatch`. While the
// HTTP request is in flight, new `enqueue` calls append to the
// fresh buffer behind it. The pending batch is removed ONLY after
// the server confirms success (or after the permanent-failure
// callback returns). A crash mid-flight leaves the pending batch
// persisted on disk; on next launch we rehydrate it and re-send
// using the same idempotency key.

import Foundation

public struct WireEvent: Sendable, Codable {
    public let id: String
    public let name: String
    public let timestamp: Date
    /// Event Envelope v1 §3 — per-session monotonic sequence number.
    /// Assigned at enqueue/track time from the session-scoped counter
    /// (see `AutoTracker.nextSeq`), reset to 0 at `session.started`.
    /// The deterministic tiebreak for events sharing a `timestamp`.
    /// Persisted on disk alongside the event so a delayed flush across
    /// a background/foreground cycle keeps its original seq.
    public let seq: Int
    public let properties: [String: AnyCodable]
    /// Event Envelope v1 §4 — standardized device/platform context,
    /// promoted OUT of `properties` into one named object. Flat string
    /// map: `os`, `osVersion`, `appVersion`, `sdkName`, `sdkVersion`,
    /// `locale`, `timezone`, plus Apple's `deviceModel`.
    public let context: [String: String]

    // Canonical Web/Node/RN bank-grade rule: ship EVERY known
    // identity axis on every event. The backend's dedup + merge
    // uses whichever axes are present; dropping any breaks
    // warehouse uniques after an identify+alias round-trip.
    public let anonymousId: String
    /// The consumer's auth-provider user ID. NOT the same as
    /// `crossdeckCustomerId`.
    public let developerUserId: String?
    /// The canonical Crossdeck-side record handle (`cdcust_…`),
    /// returned from `/identity/alias` and persisted in `Identity`.
    /// Stamped on every event when known so server-side dedup
    /// converges immediately after an identify round-trip.
    public let crossdeckCustomerId: String?

    public init(
        id: String,
        name: String,
        timestamp: Date,
        seq: Int = 0,
        properties: [String: AnyCodable],
        context: [String: String] = [:],
        anonymousId: String,
        developerUserId: String?,
        crossdeckCustomerId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.seq = seq
        self.properties = properties
        self.context = context
        self.anonymousId = anonymousId
        self.developerUserId = developerUserId
        self.crossdeckCustomerId = crossdeckCustomerId
    }
}

/// Minimal Codable wrapper for heterogenous JSON values inside
/// event properties. We don't need the entire AnyCodable ecosystem
/// — events flow String / Int / Double / Bool / [Any] / [String:Any]
/// after the scrubber, so this small wrapper is sufficient.
///
/// `@unchecked Sendable` is correct here: the wrapper stores `Any`
/// which the type system can't prove is Sendable, but at runtime
/// the values are always JSON primitives (String/Int/Double/Bool/
/// NSNull) or value-type containers, all of which ARE Sendable.
/// The scrubber + validator at the SDK boundary guarantee no
/// reference types survive to this wrapper.
public struct AnyCodable: @unchecked Sendable, Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int64.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map { $0.value }; return
        }
        if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }; return
        }
        self.value = NSNull()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double:
            if d.isFinite { try c.encode(d) } else { try c.encodeNil() }
        case let f as Float:
            if f.isFinite { try c.encode(f) } else { try c.encodeNil() }
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]: try c.encode(dict.mapValues(AnyCodable.init))
        default:
            // Defence in depth — should never happen if validate()
            // ran first, but if it does, encode the type name as a
            // string so the payload still serialises.
            try c.encode("<crossdeck:unencodable:\(type(of: value))>")
        }
    }
}

/// Callback invoked when a batch fails permanently (4xx or
/// retry budget exhausted). The callback is your last chance to
/// observe events that will never be delivered — typical use is
/// logging them to your own observability stack and surfacing a
/// user-visible diagnostic for invalid_request_error cases.
public typealias PermanentFailureHandler = @Sendable (_ events: [WireEvent], _ error: CrossdeckError) -> Void

/// Callback invoked when the server PARKS this SDK (HTTP 426 /
/// `sdk_version_unsupported`): the wire dialect is too old. Unlike
/// `PermanentFailureHandler`, the events are NOT lost — they're held in
/// the durable queue and delivered on the next launch after the app
/// upgrades the SDK. The host surfaces this to the developer console once
/// and to the dashboard via the heartbeat. `minVersion` is the required
/// floor when the server supplies it.
public typealias ParkedHandler = @Sendable (_ minVersion: String?, _ surface: String?) -> Void

public struct EventQueueConfig: Sendable {
    public var batchSize: Int = 20
    /// v1.4.0 Phase 3.3 — flush interval default parity at 2000ms
    /// across every Crossdeck SDK. Pre-v1.4.0 Swift used 5000ms,
    /// out of step with Web/Node's 1500ms; v1.4.0 converged on
    /// 2000ms (Stripe-adjacent industry norm). Per-instance
    /// override stays — call sites can still tune it freely.
    public var flushIntervalMs: Int = 2_000
    public var maxBufferSize: Int = 1_000
    public var retry: RetryPolicy = RetryPolicy()
    public init() {}
}

/// Batch envelope context — `appId` + `environment` (+ the SDK
/// identifier baked in from `SDK.name` / `SDK.version`) attached
/// to every batch POST. Matches the NorthStar §13.1 envelope the
/// backend validator expects.
public struct EventQueueEnvelope: Sendable {
    public let appId: String
    public let environment: CrossdeckEnvironment

    public init(appId: String, environment: CrossdeckEnvironment) {
        self.appId = appId
        self.environment = environment
    }
}

public struct QueueStats: Sendable {
    public let buffered: Int
    public let pending: Int
    public let attemptsForPending: Int
    public let nextRetryAt: Date?
}

private struct PendingBatch: Sendable, Codable {
    let events: [WireEvent]
    let idempotencyKey: String
    var attempt: Int
    var nextRetryAt: Date?
}

public actor EventQueue {
    private let http: HTTPClient
    private let storage: Storage
    private let envelope: EventQueueEnvelope
    private let logger: DebugLogger
    private let onPermanentFailure: PermanentFailureHandler?
    private let onParked: ParkedHandler?
    private let config: EventQueueConfig

    /// PARK state (HTTP 426 / `sdk_version_unsupported`). Once parked, the
    /// queue stops flushing — retrying a known-too-old payload only wastes
    /// the device's battery and bandwidth until the app ships an upgraded
    /// SDK. The held events stay durable (disk) and deliver on the next
    /// launch's rehydrate, post-upgrade. Per-instance: a fresh launch starts
    /// unparked, retries once, and either delivers (upgraded) or re-parks.
    private var parked: Bool = false
    /// One developer-facing console warning per process — never per-event spam.
    private var parkWarned: Bool = false

    /// One-shot guard for `sdk.first_event_sent`. The dashboard
    /// onboarding checklist fires when it sees this signal, so it
    /// must fire EXACTLY ONCE per process lifetime (matches Web/Node/RN
    /// semantics). Subsequent flushes emit `sdk.queue_persisted`.
    private var firstEventSentFired: Bool = false

    private var buffer: [WireEvent] = []
    private var pendingBatch: PendingBatch?
    private var flushTask: Task<Void, Never>?
    private var nextRetryAt: Date?

    private let pendingStorageKey = "queue.pending.v1"
    private let bufferStorageKey = "queue.buffer.v1"

    public init(
        http: HTTPClient,
        storage: Storage,
        envelope: EventQueueEnvelope,
        logger: @escaping DebugLogger = noopDebugLogger,
        onPermanentFailure: PermanentFailureHandler? = nil,
        onParked: ParkedHandler? = nil,
        config: EventQueueConfig = EventQueueConfig()
    ) {
        self.http = http
        self.storage = storage
        self.envelope = envelope
        self.logger = logger
        self.onPermanentFailure = onPermanentFailure
        self.onParked = onParked
        self.config = config

        // Rehydrate inline. Method calls from actor init flag
        // "actor-isolated method from nonisolated context" under
        // Swift 6 strict concurrency, so we open-code the storage
        // reads here. Two single-block reads — not worth the
        // ceremony of a nonisolated helper.
        if let blob = storage.getString(bufferStorageKey),
           let data = blob.data(using: .utf8),
           let restored = try? JSONDecoder().decode([WireEvent].self, from: data) {
            self.buffer = restored
        }
        if let blob = storage.getString(pendingStorageKey),
           let data = blob.data(using: .utf8),
           let restored = try? JSONDecoder().decode(PendingBatch.self, from: data) {
            self.pendingBatch = restored
            self.nextRetryAt = restored.nextRetryAt
        }
    }

    // MARK: - Public API

    public func enqueue(_ event: WireEvent) async {
        if buffer.count >= config.maxBufferSize {
            // Overflow protection: drop OLDEST events so the newest
            // signal (most likely to be diagnostically useful) is
            // preserved. Web/RN SDKs do the same.
            let overflow = buffer.count - config.maxBufferSize + 1
            buffer.removeFirst(overflow)
            logger(.sdkFlushPermanentFailure, ["dropped": String(overflow)])
        }
        buffer.append(event)
        persistBuffer()
        logger(.sdkQueuePersisted, ["name": event.name, "buffered": String(buffer.count)])

        if buffer.count >= config.batchSize {
            await flush()
        }
    }

    public func flush() async {
        // PARK hush: once the server has rejected our wire dialect as too
        // old (426), every flush of the same-format payload fails
        // identically. Hold — don't flush — until the next launch on an
        // upgraded SDK. The events stay buffered + persisted, so they
        // deliver on that launch's rehydrate.
        if parked { return }
        if pendingBatch == nil {
            // Promote a fresh batch from the head of the buffer.
            guard !buffer.isEmpty else { return }
            let take = min(config.batchSize, buffer.count)
            let head = Array(buffer.prefix(take))
            buffer.removeFirst(take)
            persistBuffer()
            pendingBatch = PendingBatch(
                events: head,
                idempotencyKey: makeIdempotencyKey(),
                attempt: 0,
                nextRetryAt: nil
            )
            persistPending()
        }

        guard var batch = pendingBatch else { return }

        // Respect scheduled retry delay.
        if let when = batch.nextRetryAt, when > Date() { return }

        logger(.sdkQueuePersisted, [
            "size": String(batch.events.count),
            "attempt": String(batch.attempt + 1),
            "idempotency_key": batch.idempotencyKey,
        ])

        let body = encodeBatch(batch.events)
        let outcome = await http.send(body: body, idempotencyKey: batch.idempotencyKey)

        switch outcome.kind {
        case .success:
            // sdk.queue_persisted = "another successful batch landed".
            // sdk.first_event_sent fires EXACTLY ONCE per process —
            // it's the signal the dashboard onboarding checklist
            // listens for. Subsequent flushes use the persisted
            // signal so the checklist doesn't blink between states.
            logger(.sdkQueuePersisted, ["size": String(batch.events.count)])
            if !firstEventSentFired {
                firstEventSentFired = true
                logger(.sdkFirstEventSent, ["size": String(batch.events.count)])
            }
            pendingBatch = nil
            storage.remove(pendingStorageKey)
            nextRetryAt = nil

            // Drain any subsequent buffered events if we're still
            // above batch size — keeps a backed-up queue from
            // waiting a full flush interval per batch.
            if buffer.count >= config.batchSize {
                await flush()
            }

        case .permanent:
            let err = outcome.error ?? CrossdeckError(
                type: .invalidRequest,
                code: "permanent_failure",
                message: "Batch rejected permanently."
            )
            logger(.sdkFlushPermanentFailure, [
                "code": err.code,
                "status": outcome.envelope.map { String($0.statusCode) } ?? "n/a",
            ])
            let events = batch.events
            pendingBatch = nil
            storage.remove(pendingStorageKey)
            nextRetryAt = nil
            // Fire-and-forget — the handler runs on its own task so
            // a slow handler doesn't block subsequent flushes.
            if let handler = onPermanentFailure {
                Task.detached { handler(events, err) }
            }

        case .parked:
            // THIRD outcome (HTTP 426 / `sdk_version_unsupported`). The data
            // is good; only the wire dialect is stale. Keep every held event
            // — fold the in-flight batch back to the FRONT of the buffer
            // (oldest-first), FIFO-cap at maxBufferSize, persist (disk) so the
            // next launch's rehydrate delivers it — then hush. The flush guard
            // above blocks further attempts until a fresh (upgraded) launch.
            parked = true
            buffer.insert(contentsOf: batch.events, at: 0)
            if buffer.count > config.maxBufferSize {
                let overflow = buffer.count - config.maxBufferSize
                buffer.removeFirst(overflow) // FIFO: evict oldest, keep newest
            }
            pendingBatch = nil
            storage.remove(pendingStorageKey)
            nextRetryAt = nil
            persistBuffer()
            let minVersion = outcome.error?.minVersion
            let surface = outcome.error?.surface
            // Distinct signal (NOT sdkFlushPermanentFailure — nothing was
            // dropped). The dashboard reads sdk.parked for the amber advisory.
            logger(.sdkParked, [
                "status": "426",
                "min_version": minVersion ?? "n/a",
                "surface": surface ?? "n/a",
            ])
            if !parkWarned {
                parkWarned = true
                // ONE developer-facing console line — the terminal/Xcode-side
                // cure that reaches them mid-debug, paired with the dashboard
                // banner. Printed unconditionally (not gated on debug logging).
                let floor = minVersion.map { " to >= \($0)" } ?? ""
                print(
                    "[Crossdeck] SDK outdated — the server is no longer accepting "
                    + "this version's event format. Your events are PARKED on-device "
                    + "(held, not lost) and will deliver automatically once you "
                    + "update the Crossdeck SDK\(floor) and ship a new build."
                )
            }
            onParked?(minVersion, surface)

        case .retryable:
            batch.attempt += 1
            let retryAfterMs = outcome.envelope?.retryAfterMs
            if let delayMs = config.retry.nextDelayMs(
                attempt: batch.attempt - 1,
                retryAfterMs: retryAfterMs
            ) {
                let when = Date().addingTimeInterval(Double(delayMs) / 1_000.0)
                batch.nextRetryAt = when
                nextRetryAt = when
                pendingBatch = batch
                persistPending()
                logger(.sdkFlushRetryScheduled, [
                    "attempt": String(batch.attempt),
                    "delay_ms": String(delayMs),
                ])
            } else {
                // Budget exhausted → permanent failure path.
                let err = outcome.error ?? CrossdeckError(
                    type: .internalError,
                    code: "retry_exhausted",
                    message: "Retry budget exhausted after \(batch.attempt) attempts."
                )
                logger(.sdkFlushPermanentFailure, [
                    "code": err.code,
                    "reason": "retry_exhausted",
                ])
                let events = batch.events
                pendingBatch = nil
                storage.remove(pendingStorageKey)
                nextRetryAt = nil
                if let handler = onPermanentFailure {
                    Task.detached { handler(events, err) }
                }
            }
        }
    }

    public func stats() -> QueueStats {
        return QueueStats(
            buffered: buffer.count,
            pending: pendingBatch?.events.count ?? 0,
            attemptsForPending: pendingBatch?.attempt ?? 0,
            nextRetryAt: nextRetryAt
        )
    }

    /// Persist everything currently in memory to storage. Called
    /// by the SDK on app-background notifications so we don't lose
    /// a buffered event to a force-quit while suspended.
    public func persistAll() {
        persistBuffer()
        persistPending()
    }

    // MARK: - Persistence

    private func persistBuffer() {
        if buffer.isEmpty {
            storage.remove(bufferStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(buffer),
              let blob = String(data: data, encoding: .utf8) else {
            return
        }
        storage.setString(blob, forKey: bufferStorageKey)
    }

    private func persistPending() {
        guard let pendingBatch else {
            storage.remove(pendingStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(pendingBatch),
              let blob = String(data: data, encoding: .utf8) else {
            return
        }
        storage.setString(blob, forKey: pendingStorageKey)
    }

    // MARK: - Helpers

    private func encodeBatch(_ events: [WireEvent]) -> Data {
        // Event Envelope v1 batch envelope (backend/docs/
        // event-envelope-spec-v1.md §1). Top-level keys:
        //   envelopeVersion, appId, environment, sdk: {name, version}, events
        // `envelopeVersion` is the schema/wire version the server
        // parses against ("can I parse this?") and is DISTINCT from
        // `sdk.version` ("which build is in the wild?") — two
        // questions, two fields, never conflated (spec §1). Integer 1;
        // bumped only on a breaking wire change. Field naming is
        // camelCase across the entire wire format, matching the
        // Web/Node/RN SDKs. Drift here causes silent ingest rejection.
        let body: [String: Any] = [
            "envelopeVersion": 1,
            "appId": envelope.appId,
            "environment": envelope.environment.rawValue,
            "sdk": [
                "name": SDK.name,
                "version": SDK.version,
            ],
            "events": events.map(eventToWire),
        ]
        do {
            return try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            // Defensive: should never happen since events were
            // validated. If it does, emit an empty batch so the
            // queue doesn't wedge.
            return Data("{\"events\":[]}".utf8)
        }
    }

    private func eventToWire(_ event: WireEvent) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (k, v) in event.properties { properties[k] = v.value }
        // Canonical wire-event field names (matches Web/Node/RN +
        // backend ClickHouse column names). Drift here causes
        // ingest validation failures.
        var out: [String: Any] = [
            "eventId": event.id,
            "name": event.name,
            // Epoch milliseconds — matches Web/Node/RN's
            // `timestamp: number` shape and the backend
            // ClickHouse `timestamp_ms` column. ISO 8601 strings
            // would fail the validator's `number` type check.
            "timestamp": Int(event.timestamp.timeIntervalSince1970 * 1000),
            // Envelope v1 §3 — per-session monotonic sequence; the
            // deterministic tiebreak for events sharing a timestamp.
            "seq": event.seq,
            // Envelope v1 §4 — standardized device/platform context,
            // promoted out of `properties`. Omitted (empty object) when
            // no device snapshot is available.
            "context": event.context,
            "anonymousId": event.anonymousId,
            "properties": properties,
        ]
        if let developerUserId = event.developerUserId {
            out["developerUserId"] = developerUserId
        }
        if let crossdeckCustomerId = event.crossdeckCustomerId {
            // Canonical Web/Node/RN axis — ship whenever known so
            // server-side dedup hits the canonical record id.
            out["crossdeckCustomerId"] = crossdeckCustomerId
        }
        return out
    }

    /// Idempotency-Key prefix is the platform-wide `batch_…`
    /// (matches Web/Node — same regex on the backend validator).
    private func makeIdempotencyKey() -> String {
        return "batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
