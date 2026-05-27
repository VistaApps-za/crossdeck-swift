// _DiagnosticTelemetry.swift
//
// Single-fire reliability telemetry for the SDK. Carries the
// `crossdeck.contract_failed` event ONE WAY to the Crossdeck
// reliability endpoint — NEVER the customer's appId, NEVER the
// customer's track() pipeline, NEVER visible in the customer's
// dashboard.
//
// Why this exists
// ──────────────────────────────────────────────────────────────────
// Crossdeck is an independent controller for SDK Diagnostic
// Telemetry (Privacy Policy §6, "Flow B"). The legitimate-interest
// basis depends on the payload remaining diagnostic-only: no
// end-user identifiers, no free-form text, no stack frames. The
// schema-lock contract at
// `contracts/diagnostics/contract-failed-payload-schema-lock.json`
// fixes the wire shape; this module is the call site that has to
// honour it.
//
// Why bypass the existing HttpClient
// ──────────────────────────────────────────────────────────────────
// The HttpClient is configured for the customer's project (their
// API key, their endpoint). Routing reliability telemetry through
// it would (a) bill against the customer's event quota and (b)
// show individual contract failures in their dashboard, which is
// neither the customer's nor Crossdeck's intent. A separate one-way
// path is the structural guarantee.
//
// PROVISIONING NOTE
// ──────────────────────────────────────────────────────────────────
// The reliability endpoint URL + publishable key below are LITERAL
// CONSTANTS shipped in the SDK. Until the reliability project is
// minted, the placeholder values disable telemetry — the function
// returns early without making a request. After provisioning, swap
// the placeholders for the real values; the same values go into the
// backend at backend/src/api/v1-sdk-diagnostic.ts.

import Foundation

internal enum _DiagnosticTelemetry {
    /// The reliability endpoint URL. Hardcoded — the SDK never reads
    /// this from configuration so a customer cannot accidentally
    /// redirect diagnostic telemetry to their own project.
    static let endpointURL = "https://api.cross-deck.com/v1/sdk/diagnostic"

    /// The reliability project's publishable key. Hardcoded for the
    /// same reason. Replace at provisioning time.
    static let publishableKey = "cd_pub_RELIABILITY_PLACEHOLDER_TO_BE_PROVISIONED"

    /// Whether the telemetry is enabled. Disabled while the
    /// reliability project is unprovisioned (placeholder key in
    /// place). Reading this branch lets us merge + ship the
    /// schema-lock + endpoint code before the reliability project
    /// exists, without firing requests to the placeholder URL.
    static var isEnabled: Bool {
        return !publishableKey.hasPrefix("cd_pub_RELIABILITY_PLACEHOLDER")
    }

    /// The exhaustive set of fields the payload may contain — mirrors
    /// the schema-lock contract. Anything outside this set is dropped
    /// at the call site so a future caller can't accidentally widen
    /// the wire shape.
    static let allowedKeys: Set<String> = [
        "contract_id",
        "sdk_version",
        "sdk_platform",
        "failure_reason",
        "run_context",
        "run_id",
        "test_file",
        "test_name",
        "device_class",
    ]

    /// Fire a `crossdeck.contract_failed` event over the reliability
    /// channel. Synchronous-looking, internally async: never blocks
    /// the caller, never throws. Failures are silently dropped — the
    /// customer's app is not affected by reliability-endpoint
    /// availability.
    ///
    /// - Parameters:
    ///   - payload: dictionary of payload fields. Keys not in
    ///     `allowedKeys` are dropped before serialisation.
    ///   - session: optional URLSession injection for tests.
    static func send(
        payload: [String: String],
        session: URLSession? = nil
    ) {
        guard isEnabled else { return }
        guard let url = URL(string: endpointURL) else { return }

        // Whitelist filter — even if a caller threads a forbidden key
        // (anonymousId, ip, etc.) through, it never hits the wire.
        // The backend would reject it anyway; this is defence in depth.
        let filtered = payload.filter { allowedKeys.contains($0.key) }
        guard !filtered.isEmpty else { return }
        guard let body = try? JSONSerialization.data(
            withJSONObject: filtered,
            options: []
        ) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("\(SDK.name)@\(SDK.version)", forHTTPHeaderField: "Crossdeck-Sdk-Version")
        request.httpBody = body
        // Short timeout — reliability telemetry must never stall the
        // host app. A failed POST is acceptable; a hung POST is not.
        request.timeoutInterval = 8.0

        let chosenSession = session ?? URLSession.shared
        let task = chosenSession.dataTask(with: request) { _, _, _ in
            // Fire-and-forget. We intentionally ignore the response —
            // there is nothing actionable to do with a failed
            // diagnostic POST, and we never want to feed a retry loop
            // that could amplify a problem.
        }
        task.resume()
    }
}
