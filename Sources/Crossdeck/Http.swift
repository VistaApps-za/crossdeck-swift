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
    private let endpoint: URL
    private let writeKey: String
    private let userAgent: String

    public init(
        endpoint: URL,
        writeKey: String,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.writeKey = writeKey
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

    public func send(body: Data, idempotencyKey: String) async -> HTTPSendOutcome {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body

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
