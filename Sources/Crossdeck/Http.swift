// URLSession-based HTTP client.
//
// One job: send a JSON body to the ingest endpoint, return a
// normalised result the queue can decide whether to retry or
// permanently fail on.
//
// Hard-coded behaviour we will not let consumers override:
//
//   * 30s request timeout. Anything longer would deadlock the queue
//     on a wedged TCP connection.
//
//   * `Idempotency-Key` header copied verbatim from the batch's
//     stable id so a server-side retry never double-inserts.
//
//   * `User-Agent` includes SDK name + version so backend logs can
//     attribute behaviour to a specific SDK release.
//
// What the consumer CAN override:
//
//   * `URLSession`. Useful for tests (mock session), for proxy
//     routing, and for App Extension contexts that share an
//     `URLSession` with the host app.
//
// What the queue gets back: status code, body data, response
// headers (so it can parse `Retry-After` and `Request-Id`). The
// queue is responsible for turning that into success / retry /
// permanent-failure, not this layer.

import Foundation

public struct HTTPResponseEnvelope: Sendable {
    public let statusCode: Int
    public let body: Data?
    public let retryAfterMs: Int?
    public let requestId: String?
}

public struct HTTPSendOutcome: Sendable {
    public enum Kind: Sendable { case success, retryable, permanent }
    public let kind: Kind
    public let envelope: HTTPResponseEnvelope?
    public let error: CrossdeckError?
}

public actor HTTPClient {
    private let session: URLSession
    /// Events endpoint — backwards-compat field, used by the queue
    /// via the legacy `send(body:idempotencyKey:)` method below.
    private let endpoint: URL
    /// Base URL (e.g. `https://api.cross-deck.com/v1`). Used by the
    /// generic `request(method:path:body:idempotencyKey:)` for every
    /// endpoint other than `/events`.
    private let baseUrl: URL
    private let publicKey: String
    private let userAgent: String

    public init(
        endpoint: URL,
        publicKey: String,
        session: URLSession? = nil,
        baseUrl: URL? = nil
    ) {
        self.endpoint = endpoint
        // If baseUrl wasn't supplied, derive it from the endpoint
        // by stripping the `/events` suffix. Preserves backwards-
        // compat with callers that only know about the events
        // endpoint while still letting the generic path work.
        self.baseUrl = baseUrl ?? endpoint.deletingLastPathComponent()
        self.publicKey = publicKey
        self.userAgent = "\(SDK.name)/\(SDK.version)"

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            // Ephemeral cache — analytics responses are not useful
            // to cache and the disk cache would waste space.
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Generic HTTP request — used by every endpoint other than the
    /// queue's `/events` POST. Returns a normalised outcome the
    /// caller can switch on the same way the queue does (success /
    /// retryable / permanent). Supports GET (body=nil) and POST.
    ///
    /// `path` is appended to the configured `baseUrl` (e.g.
    /// `path: "/sdk/heartbeat"` → `https://api.cross-deck.com/v1/sdk/heartbeat`).
    /// Leading slash on `path` is normalised — both `"/foo"` and
    /// `"foo"` work the same way.
    ///
    /// `query` is serialised as URL-encoded query string. Required
    /// by GET endpoints that take identity hints (`/entitlements`
    /// needs at least one of customerId/userId/anonymousId).
    ///
    /// `idempotencyKey` is sent as the `Idempotency-Key` header
    /// when provided. Set for any mutating call where retry-safety
    /// matters (alias, syncPurchases). GET-shaped calls leave it nil.
    public func request(
        method: String,
        path: String,
        body: Data? = nil,
        query: [String: String]? = nil,
        idempotencyKey: String? = nil
    ) async -> HTTPSendOutcome {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var url = baseUrl.appendingPathComponent(trimmed)
        if let query, !query.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let composed = components.url { url = composed }
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Crossdeck-Sdk-Version header lets the backend populate the
        // per-SDK-surface dashboard tile (sdkHeartbeats.{surface}).
        // Drift here means the "iOS / macOS · Swift SDK" badge stays
        // dark even though events are landing. Match Web/Node/RN
        // header naming exactly.
        req.setValue("\(SDK.name)@\(SDK.version)", forHTTPHeaderField: "Crossdeck-Sdk-Version")
        if let idempotencyKey {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return await dispatch(req)
    }

    public func send(body: Data, idempotencyKey: String) async -> HTTPSendOutcome {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Same per-SDK-surface registration as the generic path —
        // the queue's batches need to register the SDK surface too.
        req.setValue("\(SDK.name)@\(SDK.version)", forHTTPHeaderField: "Crossdeck-Sdk-Version")
        req.httpBody = body
        return await dispatch(req)
    }

    private func dispatch(_ req: URLRequest) async -> HTTPSendOutcome {

        do {
            let (data, response) = try await session.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse else {
                return HTTPSendOutcome(
                    kind: .retryable,
                    envelope: nil,
                    error: CrossdeckError(
                        type: .network,
                        code: "non_http_response",
                        message: "Response was not an HTTP response."
                    )
                )
            }

            let retryAfterMs = parseRetryAfterHeader(
                httpResponse.value(forHTTPHeaderField: "Retry-After")
            )
            let requestId = httpResponse.value(forHTTPHeaderField: "Request-Id")
                ?? httpResponse.value(forHTTPHeaderField: "X-Request-Id")

            let envelope = HTTPResponseEnvelope(
                statusCode: httpResponse.statusCode,
                body: data,
                retryAfterMs: retryAfterMs,
                requestId: requestId
            )

            // 2xx → success
            if (200...299).contains(httpResponse.statusCode) {
                return HTTPSendOutcome(kind: .success, envelope: envelope, error: nil)
            }

            // 4xx (excluding 408 + 429) → permanent. Caller fix needed.
            // 408 is request timeout — server-side hint to retry.
            // 429 is rate limit — retry with Retry-After.
            let status = httpResponse.statusCode
            let isPermanent4xx = (400...499).contains(status) && status != 408 && status != 429

            let err = crossdeckErrorFrom(response: httpResponse, body: data)

            if isPermanent4xx {
                return HTTPSendOutcome(kind: .permanent, envelope: envelope, error: err)
            }

            // 408 / 429 / 5xx → retryable
            return HTTPSendOutcome(kind: .retryable, envelope: envelope, error: err)
        } catch let urlError as URLError {
            // Map cancellation to permanent so the queue doesn't
            // burn retries on an actively-cancelled request.
            let kind: HTTPSendOutcome.Kind = (urlError.code == .cancelled) ? .permanent : .retryable
            return HTTPSendOutcome(
                kind: kind,
                envelope: nil,
                error: CrossdeckError(
                    type: .network,
                    code: "url_error_\(urlError.code.rawValue)",
                    message: urlError.localizedDescription
                )
            )
        } catch {
            return HTTPSendOutcome(
                kind: .retryable,
                envelope: nil,
                error: CrossdeckError(
                    type: .network,
                    code: "transport_error",
                    message: String(describing: error)
                )
            )
        }
    }
}

// MARK: - Self-request detection (used by error capture)

/// Extract a hostname from an arbitrary URL string. Returns nil
/// for malformed URLs. Result is lowercased so subsequent compares
/// are case-insensitive without per-comparison `caseInsensitiveCompare`.
public func extractSelfHostname(from urlString: String) -> String? {
    guard let url = URL(string: urlString), let host = url.host else { return nil }
    return host.lowercased()
}

/// Is the given URL a request to the SDK's own ingest endpoint?
/// Used by the network-error capture to skip its own outgoing
/// requests — without this guard, a failed ingest would generate
/// an error event, which would itself fail, which would generate
/// another error event… a perfect feedback loop.
public func isSelfRequest(urlString: String, selfHostname: String?) -> Bool {
    guard let selfHostname, !selfHostname.isEmpty else { return false }
    guard let candidate = extractSelfHostname(from: urlString) else { return false }
    return candidate == selfHostname.lowercased()
}
