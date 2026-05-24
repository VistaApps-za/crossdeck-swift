# Changelog

All notable changes to `@cross-deck/swift` will be documented in
this file. Format follows [Keep a Changelog](https://keepachangelog.com/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-05-24

Initial release. Brings the Crossdeck Swift SDK to the same
bank-grade contract as the Web and Node SDKs.

### Event ingestion

- Durable, deduplicated, batched event queue. Pending batch lives in
  a dedicated slot held across retries — a crash mid-flight does
  NOT lose the batch; it rehydrates from `UserDefaults` on relaunch
  and re-sends with the original `Idempotency-Key`.
- 4xx hard stop. Permanent failures (`invalid_request_error`,
  `authentication_error`, `permission_error`) drain through the
  `onPermanentFailure` callback and never block newer events.
- `Retry-After` honoured even above the local `maxMs`, clamped at
  24h as a sanity ceiling against pathological server responses.
- Buffer overflow drops OLDEST events, preserving the most-recent
  diagnostic signal.

### Error capture

- Uncaught `NSException` handler installs an SDK-aware bridge.
- Manual `captureError(...)` for handled errors. Both paths attach
  a normalised stack + breadcrumb ring buffer.
- `beforeSend` hook for per-error filter / mutation (return `nil`
  to drop).
- Self-request detection: HTTP failures against the SDK's own
  ingest endpoint are skipped to prevent feedback loops.

### Identity + entitlements

- `anonymousId` persisted in `UserDefaults`, regenerated only on
  `reset()`.
- `identify(...)` unconditionally clears the entitlement cache so
  a switched-customer never inherits the prior user's entitlements.
- Entitlement cache scoped on `(customerId, entitlements)` — reads
  for a different customer return `nil`, never the wrong set.

### Privacy

- PII scrubber on by default. `<email>` and `<card>` tokens (angle-
  bracketed) match the platform-wide vocabulary across Web/Node/RN
  and backend.
- Recursive walk over nested dictionaries + arrays.
- Default-deny consent state: both analytics and errors off until
  the consumer opts in via `setConsent(...)`.

### Concurrency

- Strict concurrency enabled in `Package.swift`.
- All shared mutable state lives behind Swift actors (`EventQueue`,
  `Identity`, `EntitlementCache`, `SuperProperties`, `Breadcrumbs`,
  `ConsentManager`).
- All cross-actor types are `Sendable`.

### Platforms

- iOS 13+, iPadOS 13+, macOS 11+, tvOS 13+, watchOS 7+.
- Zero runtime dependencies.
