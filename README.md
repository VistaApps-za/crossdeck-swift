# Crossdeck — Swift SDK

The Crossdeck SDK for iOS, iPadOS, macOS, tvOS, and watchOS.

> **Status: v1.2.0 — full bank-grade parity.** Modeled line-for-line
> on the Web/Node/React Native SDKs. v1.2.0 adds **auto-tracking**
> (sessions, screen views, tap autocapture) so journeys appear in
> your dashboard with zero instrumentation, **PrivacyInfo.xcprivacy**
> bundled in the SDK (Apple requires this since May 2024 — without
> it your app is rejected at submit), **MetricKit perf vitals**
> (hang detection, cold launch time, CPU exceptions), **network-
> edge flush** for offline→online recovery, **automatic StoreKit 2
> transaction observation**, and **deep-link / push attribution
> helpers**. v1.2.0 made `track`, `identify`, `reset` non-throwing.
> See [`CHANGELOG.md`](./CHANGELOG.md) for full details and a
> compatibility table.

## Three pillars

| Pillar | What it does | Why it matters |
| ------ | ------------ | -------------- |
| **Events** | Durable, deduplicated, batched event ingest. Survives crashes / offline / process suspension. | Your funnels, cohorts, and revenue analytics rest on this never losing or double-counting an event. |
| **Errors** | Uncaught `NSException` capture, manual `captureError(...)`, stack normalisation, breadcrumbs, beforeSend hook. | When something breaks in prod, you get the actual stack + the user's last 50 actions, not "TypeError: undefined". |
| **Entitlements** | Synchronous read of "is this customer entitled to feature X?" with on-device cache and async refresh. | Paywall gates without a network round-trip. |

## Auto-tracking (v1.2.0+)

The SDK ships with **default-on auto-tracking** — your dashboard
sees user journeys without any `track(...)` calls in your code.
Event names match the Web/Node/RN SDKs so cross-platform funnels
work with a single query:

| Event | Fires when | Properties |
| ----- | ---------- | ---------- |
| `session.started` | First `start()` of the process, or foreground after >30 min idle. | `sessionId`, `reason` |
| `session.ended` | App enters background, terminates, or session manually reset. | `sessionId`, `durationMs`, `reason` |
| `page.viewed` | Any `UIViewController.viewDidAppear` (including SwiftUI's `NavigationStack` host controllers). | `screen` (class name), `title`, `restorationId` |
| `element.clicked` | Any UIControl action (UIButton, UISwitch, UISlider, UISegmentedControl) AND any SwiftUI button tap that resolves to an accessibility-labelled view. | `element`, `accessibilityLabel`, `accessibilityId`, `title`, `viewportX`, `viewportY` |

Every event the SDK ships — auto-track and your own `track(...)` calls
— carries `sessionId` so funnels reconstruct cleanly.

**Privacy guardrails baked in:**

- Secure text fields (`isSecureTextEntry`) and accessibility labels
  matching `password` / `card` / `ssn` / `credit` / `cvv` / `pin` are
  skipped silently — no opt-in needed, no PII leaves the device.
- Per-element opt-out via the standard accessibility identifier
  convention: set `view.accessibilityIdentifier = "cd-noTrack"` (or
  include the substring) and Crossdeck skips it.

**Configure** via `CrossdeckOptions.autoTrack`:

```swift
// Disable tap autocapture but keep sessions + screens
let options = CrossdeckOptions(
    appId: "app_ios_xxx",
    publicKey: "cd_pub_live_…",
    environment: .production,
    autoTrack: AutoTrackConfig(
        sessions: true,
        screenViews: true,
        taps: false,
        sessionResumeThresholdSeconds: 30 * 60
    )
)

// Or disable everything (strict-consent flow)
let strict = CrossdeckOptions(
    appId: "app_ios_xxx",
    publicKey: "cd_pub_live_…",
    environment: .production,
    autoTrack: .off
)
```

## Install

### Swift Package Manager (Xcode UI)

1. **File → Add Package Dependencies…**
2. Paste the URL into the search field:

   ```
   https://github.com/VistaApps-za/crossdeck-swift.git
   ```

3. In the **Dependency Rule** dropdown on the right, select **"Up to Next Major Version"** and enter `1.2.0`. Do **not** leave it set to **"Branch: main"** — branch tracking auto-pulls every commit including breaking changes when v2.0.0 lands. The Major-Version rule gives you patch + minor updates automatically and lets you choose when to take breaking changes.
4. Click **Add Package**. Xcode resolves the package and offers to add the `Crossdeck` library product to your app target — accept.

> **If your Xcode UI already shows `Dependency Rule: Branch — main` from a pre-v1.0.0 add**, the *File → Add Package Dependencies…* dialog is hard-blocked from changing rules on already-added packages — the Dependency Rule dropdown greys out with "already depends on … with rule main" at the bottom. Removing and re-adding usually loops, too: Xcode's *Recently Used* auto-suggests the package back in with the dropdown still greyed.
>
> Change the rule from the project's Package Dependencies tab instead:
>
> 1. In the file navigator, click your project's top-level entry (the blue Xcode icon).
> 2. In the editor pane, select your project under the **PROJECT** column — **not** under TARGETS (the rule editor only lives on the project, not the target).
> 3. Click the **Package Dependencies** tab.
> 4. **Double-click** the `crossdeck-swift` row. A sheet opens with the Dependency Rule editor — this is the only UI in Xcode that can change a rule on an already-added package.
> 5. Change `Branch` → `Up to Next Major Version`, set the version to `1.2.0`, click `Done`.
>
> If double-click doesn't open the sheet, try right-click → *Modify Package Settings* (label varies by Xcode version).
>
> **Bulletproof fallback (no Xcode UI):** quit Xcode, edit `YourProject.xcodeproj/project.pbxproj` by hand, change `requirement = { branch = main; … }` to `requirement = { kind = upToNextMajorVersion; minimumVersion = 1.2.0; }`, save, reopen.

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/VistaApps-za/crossdeck-swift.git",
        from: "1.2.0"
    ),
]
```

`from: "1.2.0"` is shorthand for "Up to Next Major Version" — same rule as the Xcode picker.

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
// Track an event — fire-and-forget, never throws (v1.2.0+).
cd?.track("paywall_seen", properties: ["variant": "annual"])

// Identify after sign-in. userId is YOUR auth provider's stable id
// (Firebase Auth uid, Sign In with Apple userIdentifier, Auth0 sub,
// Supabase id, etc.) — never a placeholder. Non-throwing in v1.2.0+.
cd?.identify(userId: user.id, email: user.email, traits: ["plan": "pro"])

// Sign-out — wipes identity + entitlement cache + super-properties +
// breadcrumbs. Regenerates anonymousId for shared-device privacy.
cd?.reset()

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
- **Clean `stop()` teardown (v1.4.0).** `Crossdeck.stop()` calls
  `ErrorCapture.shared.uninstall()` so the global exception hook
  releases its references to the stopped client. A subsequent
  `start()` reinstalls cleanly. **Apple platform caveat:**
  `NSSetUncaughtExceptionHandler` has no removal API; if your app
  installed an exception handler before Crossdeck did,
  uninstall() restores the chained prior handler so it continues
  to receive uncaught exceptions after the SDK stops.
- **Lifecycle observer cleanup (v1.4.0).** `stop()` deregisters
  every `NSNotificationCenter` observer the SDK installed for
  background-flush / will-terminate / persist-all. Pre-v1.4.0
  every start→stop→start cycle leaked observers; each subsequent
  `didEnterBackgroundNotification` fired N stacked
  `queue.flush()` calls against dead Crossdecks.

### Entitlements

- **Customer-scoped.** The cache key is `(developerUserId, entitlements)`.
  A read for a different customer returns `false` — never leaks a
  prior user's entitlements after identify.
- **Synchronous read.** `isEntitled(...)` returns instantly from
  cache. Paywall gates do not block on network.

### Purchases — `appAccountToken` contract (v1.4.0)

Apple defines `appAccountToken` as a **UUID** in the StoreKit contract.
Pre-v1.4.0 the auto-track path stuffed the numeric
`originalTransactionId` into this field — passing the SDK but
violating the StoreKit contract and any downstream system that
interpreted the value as a UUID. The wire shape is fixed in v1.4.0:

- **`appAccountToken`** is derived from `developerUserId` via
  `AppAccountTokenDerivation`:
  - If the id parses as a UUID, use it directly.
  - Else derive RFC 4122 UUID v5 from the URL namespace +
    `crossdeck:<id>` (deterministic — resubmitting the same purchase
    produces the same token, which Apple uses for cross-receipt
    linkage).
  - Else omit the field — never silently send a wrong UUID.
- **`originalTransactionId`** is now sent in its own dedicated wire
  field. StoreKit's numeric id never collides with the UUID slot.
- The backend validator **rejects non-UUID `appAccountToken`** with
  400 as of v1.4.0. Pre-1.4.0 SDK builds will start receiving
  `appAccountToken must be in canonical RFC 4122 UUID format`
  responses. Upgrade the SDK to fix.

### Purchases (StoreKit 2 auto-track)

Enable with `CrossdeckOptions(automaticPurchaseTracking: true)`. Off
by default — opt in if you don't already call `syncPurchases()` from
your own `Transaction.updates` listener.

- **`transaction.finish()` iff backend acknowledged.** Bank-grade
  invariant: the SDK calls `transaction.finish()` STRICTLY inside
  the success branch of `/purchases/sync`. A 5xx during sync leaves
  the StoreKit transaction unfinished so Apple's re-delivery on the
  next session keeps the purchase alive — mid-process-death plus
  a transient backend outage CANNOT silently lose revenue.
- **In-process retry queue.** A failed sync is persisted to the
  `PendingPurchaseQueue` (UserDefaults-backed; injectable via
  `CrossdeckOptions.storage`). A background drain task wakes every
  30s, finds entries whose `nextRetryAt` has elapsed, and
  re-attempts the sync via the matching `Transaction.unfinished`
  entry. On success: `.finish()` + clear. On failure: re-record
  with the next backoff.
- **Bounded retries, exponential backoff.** Max 5 in-process
  attempts at 30s / 1m / 5m / 30m / 2h. Beyond the cap the queue
  entry is dropped but the StoreKit transaction REMAINS
  unfinished — Apple's re-delivery on the next session takes over.
  We never pretend to know better than the platform.
- **Failure telemetry.** A failed sync emits a `purchase.sync_failed`
  event (and `purchase.sync_retry_failed` on subsequent retries)
  with typed `errorType` / `errorCode` / `statusCode` /
  `originalTransactionId` so dashboards surface the revenue at risk
  in real time.

### Lifecycle — async stop() + async reset() (v1.4.0)

**Breaking from v1.3.x.** Both `stop()` and `reset()` are now
`async` so the caller knows when teardown is durably complete.

```swift
// Logout / sign-out
await crossdeck.reset()   // awaits identity/cache/super-prop wipe

// SDK teardown (test cleanup, app shutdown)
await crossdeck.stop()    // awaits queue.persistAll() before returning
```

If the caller cannot await (deinit, signal handler, non-async
SwiftUI button handler), use the sync variants:

```swift
crossdeck.stopSync()   // module teardown without awaiting persist
crossdeck.resetSync()  // tombstone flips synchronously; clear runs in detached Task
```

**Bank-grade tombstone (Phase 2.3).** During the `reset()` clear
window, `isEntitled` returns `false` IMMEDIATELY via an
`isResetting` tombstone — closes the race between a logout button
firing `reset()` and the actor-internal clear completing, where a
paywall gate could otherwise read the prior identified user's
cached entitlements between caller invocation and actor work.

**Bank-grade Task cancellation (Phase 5.3).** Background Tasks
spawned at `start()` (boot flush, heartbeat) are stored as
instance properties; `stop()` cancels them cooperatively before
returning. Pre-v1.4.0 they were fire-and-forget with no handle
and would keep running against released actors of a stopped
client. Cancellation propagates through `URLSession` so in-flight
HTTP aborts cleanly.

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

## Troubleshooting

### "Missing package product 'Crossdeck'" / "no such module 'Crossdeck'"

The package is in your Package Dependencies but the library product isn't linked to your app target's Frameworks list. Almost always shows up after removing + re-adding a package — often on multiple packages at once (`FirebaseAuth`, `Crossdeck`, `GoogleSignIn` all missing in one build is the same Xcode behaviour, not three different problems).

**Fix — same steps for any Swift package:**

1. Click your project file (blue Xcode icon) in the navigator.
2. Select your app target under the **TARGETS** column.
3. Click the **General** tab.
4. Scroll to **Frameworks, Libraries, and Embedded Content**.
5. Click `+`. The picker shows every product across all your packages.
6. Select the missing product (`Crossdeck` under `crossdeck-swift`). Repeat for `FirebaseAuth`, `GoogleSignIn`, etc.
7. Build.

### `'Logger' is only available in iOS 14.0 or newer` (and similar)

You're on Crossdeck v1.0.0–v1.0.2 with a deployment target below iOS 14. Upgrade to **v1.2.0** — `defaultDebugLogger()` is now availability-gated and falls back to `os_log` on iOS 13. **File → Packages → Update To Latest Package Versions** pulls v1.2.0 if your rule is *Up to Next Major Version*.

### `Branch: main` rule won't change

See the recovery flow inside the **Install** section above. Short version: double-click the row in the project's **Package Dependencies** tab — don't fight the *File → Add Package Dependencies…* dialog (it's hard-blocked from changing rules on existing dependencies).

## Platforms

- iOS 13+ / iPadOS 13+ (StoreKit 2 purchase rail requires iOS 15+; `defaultDebugLogger()` falls back to `os_log` below iOS 14)
- macOS 11+
- tvOS 13+
- watchOS 7+

## Dependencies

**Zero.** The SDK is implemented against `Foundation`, `URLSession`,
and `os.Logger` only — your build never inherits a third-party
version conflict from us.

## License

MIT — see [LICENSE](./LICENSE).
