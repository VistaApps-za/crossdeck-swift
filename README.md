# Crossdeck — Swift SDK

The Crossdeck SDK for iOS, iPadOS, macOS, tvOS, and watchOS.

> **Status: v1.0.0 — bank-grade.** Modeled line-for-line on the
> Web/Node/React Native SDKs. All three pillars (analytics events,
> error capture, entitlement gating) live in one Swift Package
> with zero runtime dependencies.

## Three pillars

| Pillar | What it does | Why it matters |
| ------ | ------------ | -------------- |
| **Events** | Durable, deduplicated, batched event ingest. Survives crashes / offline / process suspension. | Your funnels, cohorts, and revenue analytics rest on this never losing or double-counting an event. |
| **Errors** | Uncaught `NSException` capture, manual `captureError(...)`, stack normalisation, breadcrumbs, beforeSend hook. | When something breaks in prod, you get the actual stack + the user's last 50 actions, not "TypeError: undefined". |
| **Entitlements** | Synchronous read of "is this customer entitled to feature X?" with on-device cache and async refresh. | Paywall gates without a network round-trip. |

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**

```
https://github.com/VistaApps-za/crossdeck-swift.git
```

Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VistaApps-za/crossdeck-swift.git", from: "1.0.0")
]
```

## Quickstart

```swift
import Crossdeck

let cd = Crossdeck.start(options: CrossdeckOptions(
    endpoint: URL(string: "https://api.cross-deck.com/v1/events")!,
    writeKey: "ck_live_..."
))

// Track an event
try? cd.track("paywall_seen", properties: ["variant": "annual"])

// Identify a customer
try? cd.identify(customerId: "cus_abc123", traits: ["plan": "pro"])

// Manual error capture
do {
    try riskyOperation()
} catch {
    cd.captureError(error)
}

// Drain before app shutdown
await cd.flush()
```

## Bank-grade contracts

These are the data-integrity guarantees the SDK ships with, and the
patterns it enforces. They are the SAME contracts that govern the
Web, Node, and React Native SDKs.

### Events

- **Never lost.** Buffered events are persisted to `UserDefaults`
  on every enqueue. The in-flight batch is held in a dedicated
  `pendingBatch` slot so a crash mid-HTTP-request leaves the batch
  intact on disk for the next launch.
- **Never double-inserted.** Each batch gets a stable
  `Idempotency-Key` reused across retries. Server-side dedup
  collapses retries to a single insert.
- **4xx hard stop.** A permanent 4xx (auth, payload broken) is
  routed to the `onPermanentFailure` callback and dropped — it
  will never block newer events behind a dead batch.
- **`Retry-After` honoured.** Server is authoritative on its own
  rate budget. Clamped at 24h as a sanity cap.

### Errors

- **`beforeSend` hook.** Final filter before an error event leaves
  the device. Return `nil` to drop.
- **Self-request skip.** The SDK's own HTTP errors against its own
  ingest endpoint are skipped — no feedback loops.
- **Breadcrumbs.** Ring buffer of the user's last 50 actions
  attached to every captured error.

### Entitlements

- **Customer-scoped.** The cache key is `(customerId, entitlements)`.
  A read for a different customer returns `nil` — never leaks a
  prior user's entitlements after identify.
- **Synchronous read.** `isEntitled(...)` returns instantly from
  cache. Paywall gates do not block on network.

### Identity

- **`anonymousId` persists across launches** until `reset()`.
- **`reset()` regenerates `anonymousId`** so the next anonymous
  session is not linked to the prior identified user.
- **Unconditional entitlement clear on identify** — a new
  customerId always wipes the prior entitlement snapshot.

### Privacy

- **PII scrubber on by default.** `<email>` and `<card>` tokens
  replace anything that looks like an email or payment card. Walks
  nested dictionaries and arrays recursively.
- **Default-deny consent.** Analytics + errors both off until you
  call `setConsent(...)`.

## Platforms

- iOS 13+ / iPadOS 13+ (StoreKit purchase rail requires iOS 15+)
- macOS 11+
- tvOS 13+
- watchOS 7+

## Dependencies

**Zero.** The SDK is implemented against `Foundation`, `URLSession`,
and `os.Logger` only — your build never inherits a third-party
version conflict from us.

## License

MIT — see [LICENSE](./LICENSE).
