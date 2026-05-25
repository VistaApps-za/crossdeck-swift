# Crossdeck — Swift SDK

The Crossdeck SDK for iOS, iPadOS, macOS, tvOS, and watchOS.

> **Status: v1.0.2 — bank-grade.** Modeled line-for-line on the
> Web/Node/React Native SDKs. All three pillars (analytics events,
> error capture, entitlement gating) live in one Swift Package
> with zero runtime dependencies. v1.0.2 adds `Crossdeck.current` —
> a process-singleton accessor for service / view-model / UIKit
> call sites where `@Environment(\.crossdeck)` isn't reachable.
> See [`CHANGELOG.md`](./CHANGELOG.md) for the full release notes.

## Three pillars

| Pillar | What it does | Why it matters |
| ------ | ------------ | -------------- |
| **Events** | Durable, deduplicated, batched event ingest. Survives crashes / offline / process suspension. | Your funnels, cohorts, and revenue analytics rest on this never losing or double-counting an event. |
| **Errors** | Uncaught `NSException` capture, manual `captureError(...)`, stack normalisation, breadcrumbs, beforeSend hook. | When something breaks in prod, you get the actual stack + the user's last 50 actions, not "TypeError: undefined". |
| **Entitlements** | Synchronous read of "is this customer entitled to feature X?" with on-device cache and async refresh. | Paywall gates without a network round-trip. |

## Install

### Swift Package Manager (Xcode UI)

1. **File → Add Package Dependencies…**
2. Paste the URL into the search field:

   ```
   https://github.com/VistaApps-za/crossdeck-swift.git
   ```

3. In the **Dependency Rule** dropdown on the right, select **"Up to Next Major Version"** and enter `1.0.2`. Do **not** leave it set to **"Branch: main"** — branch tracking auto-pulls every commit including breaking changes when v2.0.0 lands. The Major-Version rule gives you patch + minor updates automatically and lets you choose when to take breaking changes.
4. Click **Add Package**. Xcode resolves the package and offers to add the `Crossdeck` library product to your app target — accept.

> **If your Xcode UI already shows `Dependency Rule: Branch — main` from a pre-v1.0.0 add**, the *File → Add Package Dependencies…* dialog is hard-blocked from changing rules on already-added packages — the Dependency Rule dropdown greys out with "already depends on … with rule main" at the bottom. Removing and re-adding usually loops, too: Xcode's *Recently Used* auto-suggests the package back in with the dropdown still greyed.
>
> Change the rule from the project's Package Dependencies tab instead:
>
> 1. In the file navigator, click your project's top-level entry (the blue Xcode icon).
> 2. In the editor pane, select your project under the **PROJECT** column — **not** under TARGETS (the rule editor only lives on the project, not the target).
> 3. Click the **Package Dependencies** tab.
> 4. **Double-click** the `crossdeck-swift` row. A sheet opens with the Dependency Rule editor — this is the only UI in Xcode that can change a rule on an already-added package.
> 5. Change `Branch` → `Up to Next Major Version`, set the version to `1.0.2`, click `Done`.
>
> If double-click doesn't open the sheet, try right-click → *Modify Package Settings* (label varies by Xcode version).
>
> **Bulletproof fallback (no Xcode UI):** quit Xcode, edit `YourProject.xcodeproj/project.pbxproj` by hand, change `requirement = { branch = main; … }` to `requirement = { kind = upToNextMajorVersion; minimumVersion = 1.0.2; }`, save, reopen.

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/VistaApps-za/crossdeck-swift.git",
        from: "1.0.2"
    ),
]
```

`from: "1.0.2"` is shorthand for "Up to Next Major Version" — same rule as the Xcode picker.

## Quickstart

`Crossdeck.start(...)` throws on misconfiguration (`invalid_secret_key`, `env_mismatch`, `missing_app_id`). Wrap in `do/catch` and store as `Optional` so a typo'd key never crashes a customer's launch:

```swift
import SwiftUI
import Crossdeck

@main
struct YourApp: App {
    let cd: Crossdeck?

    init() {
        cd = Self.startCrossdeck()
    }

    var body: some Scene {
        WindowGroup { ContentView().environment(\.crossdeck, cd) }
    }

    private static func startCrossdeck() -> Crossdeck? {
        // Drive both from build configuration — Debug builds can never
        // accidentally embed a live key. Publishable-key prefix is
        // authoritative: cd_pub_live_ ↔ .production, cd_pub_test_ ↔
        // .sandbox. Mismatch throws env_mismatch.
        #if DEBUG
        let publicKey = "cd_pub_test_..."
        let environment: Environment = .sandbox
        #else
        let publicKey = "cd_pub_live_..."
        let environment: Environment = .production
        #endif
        do {
            return try Crossdeck.start(options: CrossdeckOptions(
                appId: "app_ios_xxx",
                publicKey: publicKey,
                environment: environment
            ))
        } catch {
            assertionFailure("[Crossdeck] start failed: \(error)")
            return nil
        }
    }
}
```

Then anywhere in your app. Inside SwiftUI views use `@Environment(\.crossdeck)`; from services / view models / non-SwiftUI surfaces use the **`Crossdeck.current`** static accessor (v1.0.2+):

```swift
// Track an event
try? cd?.track("paywall_seen", properties: ["variant": "annual"])

// Identify after sign-in. userId is YOUR auth provider's stable id
// (Firebase Auth uid, Sign In with Apple userIdentifier, Auth0 sub,
// Supabase id, etc.) — never a placeholder.
try? cd?.identify(userId: user.id, email: user.email, traits: ["plan": "pro"])

// Sign-out — wipes identity + entitlement cache + super-properties +
// breadcrumbs. Regenerates anonymousId for shared-device privacy.
try? cd?.reset()

// Synchronous paywall gate — safe inside a SwiftUI body { }
if cd?.isEntitled("pro") == true { showProFeatures() }

// Manual error capture
do { try riskyOperation() }
catch { cd?.captureError(error, handled: true) }

// From a service / view model / AppDelegate (no @Environment access):
Crossdeck.current?.track("background_refresh_completed")
if Crossdeck.current?.isEntitled("pro") == true { … }
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

- **Customer-scoped.** The cache key is `(developerUserId, entitlements)`.
  A read for a different customer returns `false` — never leaks a
  prior user's entitlements after identify.
- **Synchronous read.** `isEntitled(...)` returns instantly from
  cache. Paywall gates do not block on network.

### Identity

- **`anonymousId` persists across launches** until `reset()`.
- **`reset()` regenerates `anonymousId`** so the next anonymous
  session is not linked to the prior identified user.
- **Unconditional entitlement clear on identify** — every call
  wipes the prior entitlement snapshot, even a same-id re-identify.
  A tiny redundant cache rebuild is cheaper than a leak.
- **Repeated identify is SAFE but not free** — each call clears the
  entitlement cache and re-fires `/identity/alias`. Most apps gate
  with a `lastIdentifiedUserId` check.

### Privacy

- **PII scrubber on by default.** `<email>` and `<card>` tokens
  replace anything that looks like an email or payment card. Walks
  nested dictionaries and arrays recursively.
- **Default-GRANT consent.** Analytics + errors both on out of the
  box — matches the Web/Node/RN platform contract. Wire
  `setConsent(...)` for an opt-out flow (cookie banner, EU age gate).

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
