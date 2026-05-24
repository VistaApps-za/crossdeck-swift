import XCTest
@testable import Crossdeck

final class RetryPolicyTests: XCTestCase {
    func test_returnsNil_pastMaxAttempts() {
        let p = RetryPolicy(maxAttempts: 3)
        XCTAssertNotNil(p.nextDelayMs(attempt: 2))
        XCTAssertNil(p.nextDelayMs(attempt: 3))
        XCTAssertNil(p.nextDelayMs(attempt: 100))
    }

    func test_growsExponentially_andCapsAtMax() {
        let p = RetryPolicy(baseMs: 100, maxMs: 1_000, factor: 2.0, maxAttempts: 10)
        // Random source pinned to 1.0 (max jitter) so we observe
        // the capped ceiling deterministically.
        let attempt5 = p.nextDelayMs(attempt: 5, randomSource: { 1.0 })
        XCTAssertNotNil(attempt5)
        XCTAssertLessThanOrEqual(attempt5!, 1_000)
    }

    func test_honoursRetryAfter_aboveMaxMs() {
        let p = RetryPolicy(baseMs: 100, maxMs: 1_000, factor: 2.0, maxAttempts: 10)
        // Server asks for 30s — exceeds the local 1s cap, but
        // server is authoritative.
        let delay = p.nextDelayMs(attempt: 0, retryAfterMs: 30_000)
        XCTAssertEqual(delay, 30_000)
    }

    func test_clamps_pathologicalRetryAfter() {
        let p = RetryPolicy()
        // Server tries to ask for 100 days — clamped at 24h.
        let delay = p.nextDelayMs(attempt: 0, retryAfterMs: 100 * 24 * 60 * 60 * 1_000)
        XCTAssertEqual(delay, retryAfterCeilingMs)
    }

    func test_parseRetryAfter_acceptsSeconds() {
        XCTAssertEqual(parseRetryAfterHeader("60"), 60_000)
        XCTAssertEqual(parseRetryAfterHeader("0"), 0)
    }

    func test_parseRetryAfter_ignoresGarbage() {
        XCTAssertNil(parseRetryAfterHeader(nil))
        XCTAssertNil(parseRetryAfterHeader(""))
        XCTAssertNil(parseRetryAfterHeader("not-a-number"))
    }
}
