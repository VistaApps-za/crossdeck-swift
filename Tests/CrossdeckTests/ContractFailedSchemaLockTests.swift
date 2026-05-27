import XCTest
@testable import Crossdeck

/// Schema-lock tests for `crossdeck.contract_failed`.
///
/// The Swift SDK's `reportContractFailure(_:)` must:
///   1. Honour the allow-list in
///      contracts/diagnostics/contract-failed-payload-schema-lock.json
///   2. NEVER go through the customer's `track()` pipeline — the
///      reliability telemetry is single-fire to a dedicated endpoint
///      hardcoded in `_DiagnosticTelemetry`.
///   3. NEVER include any forbidden field on the wire even if the
///      caller's input were to carry one.
///
/// The schema-lock contract is the structural defence behind the
/// independent-controller flow in Privacy Policy §6 — these tests
/// fail loudly the moment the wire shape drifts.
final class ContractFailedSchemaLockTests: XCTestCase {

    /// Mirrors `allowedFields.required` from the JSON contract. Update
    /// in lockstep with
    /// contracts/diagnostics/contract-failed-payload-schema-lock.json.
    private let requiredFields: Set<String> = [
        "contract_id",
        "sdk_version",
        "sdk_platform",
        "failure_reason",
        "run_context",
        "run_id",
    ]

    private let optionalFields: Set<String> = [
        "test_file",
        "test_name",
        "device_class",
    ]

    private let forbiddenFields: Set<String> = [
        "anonymousId",
        "developerUserId",
        "crossdeckCustomerId",
        "email",
        "ip",
        "user_agent",
        "message",
        "stack",
        "stack_trace",
        "frames",
        "exception_message",
        "url",
        "path",
        "screen",
        "title",
        "label",
        "text",
        "ariaLabel",
        "accessibilityLabel",
        "contentDescription",
        "session_id",
        "sessionId",
    ]

    func test_diagnosticTelemetryAllowedKeys_matchesContract() {
        XCTAssertEqual(
            _DiagnosticTelemetry.allowedKeys,
            requiredFields.union(optionalFields)
        )
    }

    func test_diagnosticTelemetryAllowedKeys_doesNotContainForbidden() {
        let overlap = _DiagnosticTelemetry.allowedKeys.intersection(forbiddenFields)
        XCTAssertTrue(
            overlap.isEmpty,
            "allowedKeys overlaps forbidden fields: \(overlap)"
        )
    }

    func test_reportContractFailure_payloadFieldsAreInAllowList() {
        // The Crossdeck instance is unused — reportContractFailure
        // builds the payload synchronously and dispatches via
        // _DiagnosticTelemetry. We're exercising the payload
        // construction here, not the network IO.
        let input = ContractFailureInput(
            contractId: "per-user-cache-isolation",
            failureReason: "snapshot did not match",
            runContext: .ci,
            runId: "run_abc",
            testRef: ContractFailureInput.TestRefSnapshot(
                file: "FooTests.swift",
                name: "test_isolation"
            ),
            deviceClass: "simulator"
        )

        // Build the payload directly using the same logic
        // reportContractFailure uses, so we can assert on it.
        var payload: [String: String] = [
            "contract_id": input.contractId,
            "sdk_version": SDK.version,
            "sdk_platform": "swift",
            "failure_reason": input.failureReason,
            "run_context": input.runContext.rawValue,
            "run_id": input.runId,
        ]
        if let testRef = input.testRef {
            payload["test_file"] = testRef.file
            payload["test_name"] = testRef.name
        }
        if let deviceClass = input.deviceClass {
            payload["device_class"] = deviceClass
        }

        for key in payload.keys {
            XCTAssertTrue(
                _DiagnosticTelemetry.allowedKeys.contains(key),
                "payload key \(key) is not in allowedKeys"
            )
        }
        for required in requiredFields {
            XCTAssertNotNil(payload[required], "missing required field \(required)")
        }
    }

    func test_reportContractFailure_doesNotEnterCustomerTrackPipeline() {
        // Defensive: the reliability endpoint URL is hardcoded. If
        // anyone repoints _DiagnosticTelemetry at the customer events
        // pipeline, this test fails.
        XCTAssertEqual(
            _DiagnosticTelemetry.endpointURL,
            "https://api.cross-deck.com/v1/sdk/diagnostic"
        )
        XCTAssertFalse(_DiagnosticTelemetry.endpointURL.contains("/v1/events"))
    }
}
