import XCTest
@testable import Crossdeck

final class ErrorsTests: XCTestCase {
    func test_errorEnvelope_decodedFromServerJSON() {
        let url = URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 422,
            httpVersion: nil,
            headerFields: ["Request-Id": "req_abc123"]
        )!
        let body = #"""
        {"error":{"type":"invalid_request_error","code":"missing_field","message":"event name is required","request_id":"req_abc123"}}
        """#.data(using: .utf8)

        let err = crossdeckErrorFrom(response: response, body: body)
        XCTAssertEqual(err.type, .invalidRequest)
        XCTAssertEqual(err.code, "missing_field")
        XCTAssertEqual(err.message, "event name is required")
        XCTAssertEqual(err.requestId, "req_abc123")
        XCTAssertEqual(err.statusCode, 422)
    }

    func test_errorEnvelope_fallsBackOnGarbageBody() {
        let url = URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        let err = crossdeckErrorFrom(response: response, body: Data("<html>nope</html>".utf8))
        // v1.4.0 wire vocabulary alignment: 5xx maps to .internalError
        // (matches backend's ApiErrorType). Pre-1.4.0 was .apiError,
        // which never appeared on the wire.
        XCTAssertEqual(err.type, .internalError)
        XCTAssertEqual(err.statusCode, 500)
        XCTAssertNotNil(err.message)
    }

    func test_errorEnvelope_reads_XRequestId_fallback() {
        let url = URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["X-Request-Id": "req_xyz"]
        )!
        let err = crossdeckErrorFrom(response: response, body: nil)
        XCTAssertEqual(err.requestId, "req_xyz")
        XCTAssertEqual(err.type, .rateLimit)
    }

    func test_descriptionIncludesAllFields() {
        let err = CrossdeckError(
            type: .invalidRequest,
            code: "missing_event_name",
            message: "event name is required",
            requestId: "req_abc",
            statusCode: 422
        )
        let s = err.description
        XCTAssertTrue(s.contains("invalid_request_error"))
        XCTAssertTrue(s.contains("missing_event_name"))
        XCTAssertTrue(s.contains("req_abc"))
        XCTAssertTrue(s.contains("422"))
    }
}
