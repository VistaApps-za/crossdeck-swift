// Stripe-style structured error envelope.
//
// Every error the SDK surfaces — whether thrown out of a public API,
// raised inside the queue, or returned to a callback — uses this same
// shape. The four fields mirror exactly what the backend's
// /v1/events endpoint returns in `{ error: { type, code, message,
// request_id } }`, so the consumer's handling code is identical for
// "server returned an error" and "the SDK refused to send your event"
// scenarios. That symmetry is what makes the integration debuggable
// without a Crossdeck-side trace.

import Foundation

/// Discriminator for the kind of failure that occurred. Mirrors
/// Stripe's `type` taxonomy — clients route on `type`, message is
/// human-readable.
public enum CrossdeckErrorType: String, Sendable, Codable {
    /// The SDK or server rejected the request as malformed. Re-trying
    /// without changing the input is guaranteed to fail again.
    case invalidRequest = "invalid_request_error"

    /// Caller is not authenticated (bad / missing API key). Operator
    /// action required — never auto-retried.
    case authentication = "authentication_error"

    /// Caller is authenticated but not authorised for the action.
    case permission = "permission_error"

    /// Rate limit hit. Honour the `Retry-After` header if present.
    case rateLimit = "rate_limit_error"

    /// Server-side issue. Safe to retry with backoff.
    case apiError = "api_error"

    /// Caller's network refused the request. Browser equivalents:
    /// `TypeError: Failed to fetch`, offline, CORS preflight refused.
    case network = "network_error"

    /// Catch-all for unmodelled failure modes.
    case unknown = "unknown_error"
}

/// Bank-grade error envelope. Conforms to `Error` so it can be
/// thrown, and `Sendable` so it can cross actor boundaries (the queue
/// surfaces these to a permanent-failure callback that may run on any
/// executor).
public struct CrossdeckError: Error, Sendable {
    public let type: CrossdeckErrorType

    /// Stable machine-readable token. Examples: `not_started`,
    /// `missing_event_name`, `invalid_event_properties`. Never
    /// localised — clients pattern-match on this.
    public let code: String

    /// Human-readable description. Free-form, may change between
    /// versions — never assert on this string.
    public let message: String

    /// Server-side request identifier. Populated when the failure
    /// originated from a backend response (extracted from the
    /// `Request-Id` / `X-Request-Id` header), so support requests can
    /// be traced end-to-end.
    public let requestId: String?

    /// HTTP status code when the error came from a network response.
    /// Lets callers distinguish 401/403/404 (permanent — fix your
    /// integration) from 5xx (transient — wait and retry).
    public let statusCode: Int?

    public init(
        type: CrossdeckErrorType,
        code: String,
        message: String,
        requestId: String? = nil,
        statusCode: Int? = nil
    ) {
        self.type = type
        self.code = code
        self.message = message
        self.requestId = requestId
        self.statusCode = statusCode
    }
}

extension CrossdeckError: LocalizedError {
    public var errorDescription: String? { message }
}

extension CrossdeckError: CustomStringConvertible {
    public var description: String {
        var parts = ["Crossdeck[\(type.rawValue):\(code)] \(message)"]
        if let requestId { parts.append("(request_id: \(requestId))") }
        if let statusCode { parts.append("[HTTP \(statusCode)]") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Response → error mapping

/// Server response envelope. Decoded from the body of any non-2xx
/// response so we surface the server's diagnosis verbatim instead of
/// the generic "HTTP 422" the user already has from the status code.
struct ServerErrorEnvelope: Decodable, Sendable {
    let error: ServerErrorBody

    struct ServerErrorBody: Decodable, Sendable {
        let type: String?
        let code: String?
        let message: String?
        let requestId: String?

        enum CodingKeys: String, CodingKey {
            case type, code, message
            case requestId = "request_id"
        }
    }
}

/// Build a `CrossdeckError` from an HTTP response. Tries the JSON
/// envelope first, then falls back to status-code-derived defaults.
/// Never throws — the server returning malformed JSON should not
/// itself cause the SDK to crash.
func crossdeckErrorFrom(
    response: HTTPURLResponse,
    body: Data?
) -> CrossdeckError {
    let requestId = response.value(forHTTPHeaderField: "Request-Id")
        ?? response.value(forHTTPHeaderField: "X-Request-Id")

    // Try to decode the structured envelope. If the body isn't JSON
    // (e.g. an HTML 502 from an upstream proxy), the decode silently
    // fails and we fall through to the status-code defaults.
    if let body, !body.isEmpty,
       let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: body) {
        let parsedType = envelope.error.type.flatMap { CrossdeckErrorType(rawValue: $0) }
        return CrossdeckError(
            type: parsedType ?? typeForStatus(response.statusCode),
            code: envelope.error.code ?? codeForStatus(response.statusCode),
            message: envelope.error.message ?? defaultMessageForStatus(response.statusCode),
            requestId: envelope.error.requestId ?? requestId,
            statusCode: response.statusCode
        )
    }

    return CrossdeckError(
        type: typeForStatus(response.statusCode),
        code: codeForStatus(response.statusCode),
        message: defaultMessageForStatus(response.statusCode),
        requestId: requestId,
        statusCode: response.statusCode
    )
}

private func typeForStatus(_ status: Int) -> CrossdeckErrorType {
    switch status {
    case 400, 422: return .invalidRequest
    case 401:      return .authentication
    case 403:      return .permission
    case 429:      return .rateLimit
    case 500...599: return .apiError
    default:       return .unknown
    }
}

private func codeForStatus(_ status: Int) -> String {
    switch status {
    case 400: return "bad_request"
    case 401: return "unauthorized"
    case 403: return "forbidden"
    case 404: return "not_found"
    case 422: return "unprocessable_entity"
    case 429: return "rate_limited"
    case 500...599: return "server_error"
    default:  return "http_\(status)"
    }
}

private func defaultMessageForStatus(_ status: Int) -> String {
    switch status {
    case 400: return "Request was malformed."
    case 401: return "Authentication failed — check your write key."
    case 403: return "Authenticated, but not permitted to perform this action."
    case 404: return "Endpoint not found."
    case 422: return "Request payload failed validation."
    case 429: return "Rate limit exceeded — back off and retry."
    case 500...599: return "Server error — Crossdeck will retry."
    default:  return "Request failed with HTTP \(status)."
    }
}

// MARK: - Retry-After parsing

/// Parse a `Retry-After` header. Spec allows either delta-seconds or
/// an HTTP-date. Returns the number of milliseconds to wait, or `nil`
/// if the header is missing / unparseable. Caller is responsible for
/// applying any sanity ceiling (e.g. 24h) — this function will
/// faithfully return whatever the server asked for.
func parseRetryAfterHeader(_ value: String?) -> Int? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
    }

    // delta-seconds form: "120"
    if let seconds = Int(raw), seconds >= 0 {
        return seconds * 1_000
    }

    // HTTP-date form: "Wed, 21 Oct 2026 07:28:00 GMT"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: raw) {
        let ms = Int((date.timeIntervalSinceNow * 1_000).rounded())
        return max(ms, 0)
    }

    return nil
}
