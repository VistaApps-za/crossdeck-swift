# Changelog

All notable changes to `@cross-deck/swift` will be documented in
this file. Format follows [Keep a Changelog](https://keepachangelog.com/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.2] — 2026-05-25

Dogfood pass on the v1.0.1 surface. One additive API change to close
the biggest friction point a first-time Swift dev hit walking the
install path; everything else is documentation / snippet polish that
ships on cross-deck.com.

### Added

- **`Crossdeck.current`** — process-singleton accessor. Returns the
  most-recently-started client, or `nil` before `start` has succeeded
  in this process / after the current client's `stop` is called.
  Thread-safe via an `NSLock`; safe to read from any actor or queue.

  ```swift
  // Anywhere outside a SwiftUI view (services, view models,
  // AppDelegate, Combine pipelines, background workers):
  Crossdeck.current?.identify(userId: user.id, email: user.email)
  Crossdeck.current?.track("paywall_seen")
  if Crossdeck.current?.isEntitled("pro") == true { … }
  ```

  Inside SwiftUI views, keep using `@Environment(\.crossdeck)` — it
  participates in dependency tracking and is the idiomatic answer
  for view bodies. The static accessor is for the 50% of the
  codebase that isn't a View.

  Bank-grade discipline: `stop()` clears the slot iff the stopped
  instance is the one currently advertised, so concurrent
  start+stop sequences on a second client never clobber the first
  client's slot.

### Changed

- No behaviour changes. Public API is strictly additive — every
  v1.0.1 caller continues to compile and behave identically.

## [1.0.1] — 2026-05-25

KPMG/PwC-grade audit pass on the v1.0.0 surface. Every finding the
audit flagged is closed in this release. Plus one critical
cross-SDK canonical rename so the Swift identity surface matches
the Web/Node/RN role-model contract exactly.

### Breaking — identity API renamed to match the platform contract

The v1.0.0 identify signature drifted from Web/Node/RN. v1.0.1
restores zero-drift parity. Migration is a one-line change:

```diff
- try? cd.identify(customerId: "user_847", traits: ["email": "wes@example.com", "plan": "pro"])
+ try? cd.identify(userId: "user_847", email: "wes@example.com", traits: ["plan": "pro"])
```

Specifically:

- `customerId:` → `userId:`. The previous name collided with
  `crossdeckCustomerId` (the cdcust_… canonical handle), confusing
  the mental model. The Web/Node/RN SDKs all use `userId`.
- `email` is now a first-class top-level argument. Previously it
  was buried inside `traits` and missed the bank-grade
  identity-merge that the Web SDK gets when email is shipped
  separately. Now hoisted to the wire as `$email` on the
  `$identify` event, matching Web/Node/RN.
- Internal `customerId` field on `Identity` renamed to
  `developerUserId` everywhere — the same name Web/Node/RN's
  `Diagnostics.developerUserId` uses.
- Wire event field renamed from `customer_id` to
  `developer_user_id` (also matches what the backend ingest
  expects).
- `EntitlementSnapshot.customerId` → `developerUserId`.
- `Identity.setCustomerIdSync(...)` → `setDeveloperUserIdSync(...)`.
- Error code `missing_customer_id` → `missing_user_id`.

The Swift SDK doc now ships native auth-provider code blocks for
Sign In with Apple, Firebase Auth iOS, and Auth0 iOS, matching
the Web SDK doc's coverage of Firebase / NextAuth / Clerk /
Supabase / Auth0 / custom backends.

### Added — sync paywall reads

- `Crossdeck.isEntitled(_:)` — synchronous bool check scoped to the
  currently identified customer. Safe to call from SwiftUI bodies
  and UIKit tap handlers. Never blocks on network.
- `Crossdeck.entitlementsForCurrentCustomer()` — synchronous set
  read. Returns nil if no customer is identified or the cache is
  cold for them.
- Internally backed by NSLock-protected mirror boxes on
  `EntitlementCache`, `Identity`, `SuperProperties`, and
  `ConsentManager`. Every actor mutation updates its sync mirror
  atomically; reads acquire the lock only.

### Fixed — bank-grade contract violations

- **NSException handler now chains into the prior handler.**
  Previous v1.0.0 overwrote the global handler, silently breaking
  Crashlytics / Sentry / Bugsnag for any consumer who turned on
  `captureUncaughtExceptions`. `ErrorCapture.install` now captures
  `NSGetUncaughtExceptionHandler()` before registering ours and
  invokes the prior handler after our snapshot.
- **PII scrubber runs on `$error` events.** Previously the error
  pipeline bypassed the scrubber — a `try?` that surfaced
  `"user jane@example.com not found"` shipped raw. Now every
  scrubbable field on the wire `$error` payload (message, stack
  symbols, breadcrumb messages + data) is run through the
  configured scrubber when `consent.scrubPII` is true.
- **Breadcrumbs attached to `$error` events.** Previously collected
  but dropped before enqueue. Now ship as
  `error.breadcrumbs: [{timestamp_ms, category, level, message, data}]`
  on the wire payload.
- **`identify(...)` unconditionally clears the entitlement cache.**
  Previous v1.0.0 only cleared on `didChange || priorId == nil`.
  Now identifies always clear, matching the documented contract
  that prevents stale entitlement leaks across customer switches.
- **Self-request skip wired into `captureError(_:)`.** Errors whose
  URL host matches the configured ingest endpoint are dropped
  before processing — closes the feedback loop where a custom-
  middleware-wrapped ingest failure would generate an `$error`
  event that itself fails, ad infinitum.
- **`track()` / `identify()` race fixed.** The pre-existing pattern
  read identity inside a Task, racing concurrent identify Tasks.
  Now reads identity synchronously on the caller's thread before
  spawning the enqueue task. Deterministic ordering between
  identify and a subsequent track.
- **Empty key validation on super-properties.** `register("", v)`
  and `registerOnce("", v)` previously wrote a null-key entry
  that landed on every wire event; now silently rejected at the
  boundary.

### Fixed — privacy + correctness

- **Errors-consent gate.** The error pipeline now honours
  `consent.errors` — previously only the analytics pipeline
  observed consent. Consumers can independently allow analytics
  while denying error capture (or vice versa).
- Removed dead code: stale `(anon, cust)` tuple in error capture
  + unused NSRange in `scrubPII`.

### Tests

- **+19 new tests** (53 → 72 total). Coverage added for: sync
  paywall reads from any thread, identify cache clearing under
  same-id idempotent calls, identify cache clearing across
  customer switches, `stop()` rejecting subsequent calls
  (idempotent stop), URL-stub HTTP tests covering 2xx success,
  4xx permanent (400/401/422), 5xx retryable, 408 retryable,
  429 + Retry-After honoured, Idempotency-Key shipped verbatim
  in the request header, User-Agent header carries SDK name +
  version.

### Notes

- Public API is additive — every v1.0.0 caller still compiles.
- The `Crossdeck` class remains `@unchecked Sendable` with a
  detailed safety comment explaining the lock pattern.

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
