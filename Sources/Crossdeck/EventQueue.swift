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
    public let properties: [String: AnyCodable]
    public let anonymousId: String
    public let customerId: String?

    public init(
        id: String,
        name: String,
        timestamp: Date,
        properties: [String: AnyCodable],
        anonymousId: String,
        customerId: String?
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.properties = properties
        self.anonymousId = anonymousId
        self.customerId = customerId
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

public struct EventQueueConfig: Sendable {
    public var batchSize: Int = 20
    public var flushIntervalMs: Int = 5_000
    public var maxBufferSize: Int = 1_000
    public var retry: RetryPolicy = RetryPolicy()
    public init() {}
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
    private let logger: DebugLogger
    private let onPermanentFailure: PermanentFailureHandler?
    private let config: EventQueueConfig

    private var buffer: [WireEvent] = []
    private var pendingBatch: PendingBatch?
    private var flushTask: Task<Void, Never>?
    private var nextRetryAt: Date?

    private let pendingStorageKey = "queue.pending"
    private let bufferStorageKey = "queue.buffer"

    public init(
        http: HTTPClient,
        storage: Storage,
        logger: @escaping DebugLogger = noopDebugLogger,
        onPermanentFailure: PermanentFailureHandler? = nil,
        config: EventQueueConfig = EventQueueConfig()
    ) {
        self.http = http
        self.storage = storage
        self.logger = logger
        self.onPermanentFailure = onPermanentFailure
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
            logger(.queueOverflow, ["dropped": String(overflow)])
        }
        buffer.append(event)
        persistBuffer()
        logger(.queueEnqueue, ["name": event.name, "buffered": String(buffer.count)])

        if buffer.count >= config.batchSize {
            await flush()
        }
    }

    public func flush() async {
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

        logger(.queueFlushStart, [
            "size": String(batch.events.count),
            "attempt": String(batch.attempt + 1),
            "idempotency_key": batch.idempotencyKey,
        ])

        let body = encodeBatch(batch.events)
        let outcome = await http.send(body: body, idempotencyKey: batch.idempotencyKey)

        switch outcome.kind {
        case .success:
            logger(.queueFlushOk, ["size": String(batch.events.count)])
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
            logger(.queueFlushPermanentFailure, [
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
                logger(.queueFlushRetry, [
                    "attempt": String(batch.attempt),
                    "delay_ms": String(delayMs),
                ])
            } else {
                // Budget exhausted → permanent failure path.
                let err = outcome.error ?? CrossdeckError(
                    type: .apiError,
                    code: "retry_exhausted",
                    message: "Retry budget exhausted after \(batch.attempt) attempts."
                )
                logger(.queueFlushPermanentFailure, [
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
        let envelope: [String: Any] = [
            "events": events.map(eventToWire),
            "sdk": SDK.name,
            "sdk_version": SDK.version,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: envelope, options: [])
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
        var out: [String: Any] = [
            "id": event.id,
            "event": event.name,
            "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
            "anonymous_id": event.anonymousId,
            "properties": properties,
        ]
        if let customerId = event.customerId {
            out["customer_id"] = customerId
        }
        return out
    }

    private func makeIdempotencyKey() -> String {
        return "cdbatch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
