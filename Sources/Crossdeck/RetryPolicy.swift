// Exponential backoff with full jitter, plus Retry-After honoring.
//
// Two mathematical properties matter for the wire-level guarantee:
//
//   1) The expected delay never exceeds `maxMs`, so a permanently
//      failing endpoint can't push our next attempt into next year.
//
//   2) Full jitter (uniform in [0, exp_delay]) prevents the classic
//      thundering-herd retry storm where every client that lost
//      connection at the same time re-tries on the same beat.
//
// The exception: if the server sent `Retry-After`, we honour it,
// even if it exceeds `maxMs`. The server is the authority on its
// own rate budget. We apply a 24h sanity cap so a hostile or
// malformed `Retry-After: 999999999` can't permanently stall the
// queue.

import Foundation

/// 24 hours in milliseconds. Hard ceiling for any `Retry-After` we
/// honour — if the server asks for longer than this, we suspect a
/// bug (theirs or ours) and clamp.
let retryAfterCeilingMs: Int = 24 * 60 * 60 * 1_000

public struct RetryPolicy: Sendable {
    public let baseMs: Int
    public let maxMs: Int
    public let factor: Double
    public let maxAttempts: Int

    public init(
        baseMs: Int = 1_000,
        maxMs: Int = 30_000,
        factor: Double = 2.0,
        maxAttempts: Int = 5
    ) {
        self.baseMs = baseMs
        self.maxMs = maxMs
        self.factor = factor
        self.maxAttempts = maxAttempts
    }

    /// Returns delay in milliseconds for a given attempt (0-indexed),
    /// or `nil` when the policy is exhausted.
    public func nextDelayMs(
        attempt: Int,
        retryAfterMs: Int? = nil,
        randomSource: () -> Double = { Double.random(in: 0..<1) }
    ) -> Int? {
        guard attempt < maxAttempts else { return nil }

        if let serverAsk = retryAfterMs, serverAsk > 0 {
            // Server is authoritative — honour up to the 24h sanity
            // cap. Note we deliberately allow this to exceed `maxMs`,
            // since the server's rate budget overrides our local
            // backoff schedule.
            return min(serverAsk, retryAfterCeilingMs)
        }

        // Cap exponent before multiplication to avoid Double overflow
        // on attempts that would otherwise compute pow(2, 60+).
        let safeExponent = min(Double(attempt), 30.0)
        let exponential = Double(baseMs) * pow(factor, safeExponent)
        let capped = min(exponential, Double(maxMs))
        let jittered = randomSource() * capped

        // Round to whole ms and clamp ≥ 0 (jitter is non-negative by
        // construction, but Double rounding could underflow to -0 in
        // pathological cases).
        return max(Int(jittered.rounded()), 0)
    }
}
