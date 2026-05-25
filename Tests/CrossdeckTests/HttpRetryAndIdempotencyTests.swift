// URLProtocol-stubbed HTTP tests for the bank-grade contracts that
// pure-function tests can't reach:
//
//   * Idempotency-Key is reused across retries of the same batch.
//   * 4xx responses are classified as PERMANENT (not retryable).
//   * 5xx responses are classified as RETRYABLE.
//   * 429 with Retry-After is RETRYABLE with the server's delay
//     honoured.
//
// The URLProtocol stub intercepts every URLSession request, scripts
// a sequence of responses, and records the request headers we ship.
// This is the standard pattern for testing URLSession-backed code
// without binding to real network.

import XCTest
@testable import Crossdeck

final class HttpRetryAndIdempotencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> HTTPClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: cfg)
        return HTTPClient(
            endpoint: URL(string: "https://stub.invalid/v1/events")!,
            publicKey: "cd_pub_test_stub",
            session: session
        )
    }

    // MARK: - Success path

    func test_send_classifies2xxAsSuccess() async {
        StubProtocol.script = [.ok(200, body: "{}", retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_1")
        XCTAssertEqual(outcome.kind, .success)
        XCTAssertEqual(outcome.envelope?.statusCode, 200)
    }

    // MARK: - 4xx hard stop

    func test_send_classifies400AsPermanent() async {
        StubProtocol.script = [.ok(400, body: #"{"error":{"type":"invalid_request_error","code":"bad_event","message":"name required"}}"#, retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_2")
        XCTAssertEqual(outcome.kind, .permanent)
        XCTAssertEqual(outcome.error?.code, "bad_event")
    }

    func test_send_classifies401AsPermanent() async {
        StubProtocol.script = [.ok(401, body: nil, retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_3")
        XCTAssertEqual(outcome.kind, .permanent)
        XCTAssertEqual(outcome.envelope?.statusCode, 401)
    }

    func test_send_classifies422AsPermanent() async {
        StubProtocol.script = [.ok(422, body: nil, retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_4")
        XCTAssertEqual(outcome.kind, .permanent)
    }

    // MARK: - 5xx + 408 + 429 are retryable

    func test_send_classifies500AsRetryable() async {
        StubProtocol.script = [.ok(500, body: nil, retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_5")
        XCTAssertEqual(outcome.kind, .retryable)
    }

    func test_send_classifies408AsRetryable() async {
        StubProtocol.script = [.ok(408, body: nil, retryAfter: nil)]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_6")
        XCTAssertEqual(outcome.kind, .retryable)
    }

    func test_send_classifies429AsRetryable_withRetryAfterHonoured() async {
        StubProtocol.script = [.ok(429, body: nil, retryAfter: "60")]
        let client = makeClient()
        let outcome = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_test_7")
        XCTAssertEqual(outcome.kind, .retryable)
        XCTAssertEqual(outcome.envelope?.retryAfterMs, 60_000)
    }

    // MARK: - Idempotency-Key shipped verbatim

    func test_send_includesIdempotencyKeyHeader() async {
        StubProtocol.script = [.ok(200, body: "{}", retryAfter: nil)]
        let client = makeClient()
        _ = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_keytest_42")
        let recorded = StubProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
        XCTAssertEqual(recorded, "cdbatch_keytest_42")
    }

    func test_send_includesUserAgentHeaderWithSDKVersion() async {
        StubProtocol.script = [.ok(200, body: "{}", retryAfter: nil)]
        let client = makeClient()
        _ = await client.send(body: Data("{}".utf8), idempotencyKey: "cdbatch_uatest")
        let ua = StubProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertTrue(ua?.contains(SDK.name) == true)
        XCTAssertTrue(ua?.contains(SDK.version) == true)
    }
}

// MARK: - URLProtocol stub

final class StubProtocol: URLProtocol {
    enum ScriptedResponse {
        case ok(Int, body: String?, retryAfter: String?)
        case error(URLError)
    }

    // Static script + recorded requests. NOT thread-safe; tests run
    // sequentially per XCTestCase by default.
    nonisolated(unsafe) static var script: [ScriptedResponse] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        script = []
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubProtocol.lastRequest = request

        guard !StubProtocol.script.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let next = StubProtocol.script.removeFirst()
        switch next {
        case .ok(let status, let body, let retryAfter):
            var headers: [String: String] = ["Content-Type": "application/json"]
            if let retryAfter { headers["Retry-After"] = retryAfter }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body, let data = body.data(using: .utf8) {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .error(let err):
            client?.urlProtocol(self, didFailWithError: err)
        }
    }

    override func stopLoading() { /* no-op */ }
}
