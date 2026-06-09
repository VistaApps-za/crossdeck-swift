# Changelog

All notable changes to `@cross-deck/swift` will be documented in
this file. Format follows [Keep a Changelog](https://keepachangelog.com/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [1.5.5] — 2026-06-09

**Matching discipline: never attribute a family-shared subscription.** The
1.5.3 currentEntitlements sweep forwarded *every* verified entitlement,
including family-shared ones — but a family-shared transaction's
`originalTransactionId` belongs to the family ORGANIZER, not the signed-in
user. Binding it (with this user's `appAccountToken` attached) would hand the
organizer's subscription to a family member: a wrong-merge, the one outcome
pillar #1 forbids.

**Fixed:**

- The auto-sweep now SKIPS transactions whose `ownershipType == .familyShared`
  for ATTRIBUTION. Access is unaffected — the family member is still entitled
  locally (the Phase 3 gate honours family-shared receipts); only the
  owner-label binding is withheld. The organizer attributes the subscription on
  their own device, where the transaction is `.purchased`. The
  `apple.entitlements_resynced` summary event gains a `skipped_family_shared`
  count for observability.

## [1.5.4] — 2026-06-09

**Access never waits for attribution.** A paying subscriber is now entitled by
their own device's signed Apple receipt the instant they open the app —
offline, before any backend round-trip — instead of waiting on the backend
entitlement cache. This is the ACCESS half of the Apple spine (1.5.3 shipped
the attribution half).

**Added:**

- **`entitlementStatus(_:) -> EntitlementStatus` — a three-state gate.**
  `.entitled` / `.notEntitled` / `.resolving`. Prefer it over `isEntitled` for
  paywalls: `.resolving` ("checking your subscription…") is the honest answer
  when the device holds a verified active subscription the SDK can't yet name
  (fresh install, never synced online, fully offline). Showing a spinner there
  instead of a paywall is what stops a flash of "not Pro" at a paying user.
  Self-heals on first connectivity. (That sliver — never online, then offline —
  is irreducible; RevenueCat carries the identical one.)

**Changed:**

- **`isEntitled(_:)` now resolves device-first.** Resolution order: a backend
  grant (persisted, offline-hydrated) wins; else a device-verified Apple
  receipt mapped to the key wins — **offline, and never revoked against an
  *absent* backend** (Apple's signature is proof of payment); else `.resolving`
  or `.notEntitled`. **Monotonic + back-compatible:** returns `true` for every
  case the old cache-only check did, plus device-verified receipts the cache
  hasn't caught up to. It never flips a genuinely entitled user to `false`.

  Reconciliation rule: **protect against backend-absent; yield to
  backend-present-and-disagrees.** The verified receipt is sacrosanct when the
  network is down, but the product→entitlement MAP is developer config — a
  reachable backend that re-sources a mapping wins (the map is rebuilt
  last-snapshot-wins from the freshest backend snapshot, so a retired
  product→key pairing can't linger on-device).

Non-iOS / pre-iOS-15 targets are unaffected — resolution stays backend-only,
exactly as before.

## [1.5.3] — 2026-06-09

**Existing Apple subscribers now self-heal on return — no migration script.**
The user↔subscription link for Apple lives per-purchase on the device, not in
your backend, so there was never anything to bulk-import; ownership has to be
backfilled as each subscriber returns. `PurchaseAutoTrack` watches
`Transaction.updates`, but that only fires for NEW/changed transactions — a
subscriber who bought before this build never linked until their next renewal.

**Added:**

- **`automaticAppleEntitlementSync` (default ON, iOS 15+).** On launch (for an
  already-identified user) and immediately after `identify()`, the SDK sweeps
  `Transaction.currentEntitlements` once and forwards each verified
  subscription's signed JWS to the same `/purchases/sync` endpoint, binding
  `originalTransactionId → developerUserId`. The existing base self-heals the
  first time each subscriber opens the migrated build — no backend script, no
  "Restore Purchases" tap.

  This is **attribution, not access** — it only puts an owner label on a paid
  subscription. It is deliberately silent (no per-sub `purchase.completed`
  funnel events; one `apple.entitlements_resynced` summary event instead),
  deduped per developerUserId per session, and idempotent (the backend derives
  a deterministic key from the JWS), so a repeated sweep never double-counts.
  A silent no-op for apps without Apple IAP.

  Opt out with `CrossdeckOptions(automaticAppleEntitlementSync: false)`. The
  manual path (`syncPurchases`) and the `Transaction.updates` auto-listener
  (`automaticPurchaseTracking`) are unchanged; all three now share one
  `/purchases/sync` closure so the wire contract never drifts.

## [1.5.2] — 2026-06-09

**Compile-fix patch on 1.5.1.** Every documented call-site — the README,
these release notes, and all of the public docs — writes the helper as
`Crossdeck.appAccountTokenForCurrentIdentity()` (static syntax), but 1.5.1
declared it `public func` (instance only). Pasting the documented snippet
produced `Instance member 'appAccountTokenForCurrentIdentity' cannot be used
on type 'Crossdeck'` on first build. Caught by a dogfood integrator.

**Added:**

- **Static overload `Crossdeck.appAccountTokenForCurrentIdentity() -> UUID`.**
  Purely additive — Swift resolves the type-level call to the new static
  form and `client.appAccountTokenForCurrentIdentity()` to the original
  instance method, so both coexist and no existing caller breaks. The
  static form delegates to the live client (`Crossdeck.current`), minting
  and persisting through the started SDK's identity store exactly as the
  instance method does. Before `start()` there is no store to own a
  persisted token, so it returns a fresh anonymous `UUID` to honour the
  non-optional "never nil" contract; the first call after `start()` mints
  the install-stable token.

  ```swift
  let token: UUID = Crossdeck.appAccountTokenForCurrentIdentity()
  let result = try await product.purchase(options: [
      .appAccountToken(token)
  ])
  ```

## [1.5.1] — 2026-05-29

**Compile-fix patch on 1.5.0.** The 1.5.0 helper signature didn't
match StoreKit's contract — `Product.PurchaseOption.appAccountToken`
takes a `UUID`, not a `String`, so the snippet in the 1.5.0 release
notes would not compile when pasted as-is. Caught by a dogfood
integrator before 1.5.0 reached anyone else. No behavioural change
beyond the type — the persisted storage representation is unchanged.

**Changed:**

- **`Crossdeck.appAccountTokenForCurrentIdentity()` now returns
  `UUID` instead of `String`.** The helper still mints a single
  RFC 4122 random UUID v4 per install, persists it under
  `crossdeck.apple_app_account_token`, and returns the same value
  forever until `reset()`. The string form is what crosses the
  wire to the backend on `identify()`; the `UUID` form is what
  StoreKit demands at purchase time. Source-incompatible only if
  you were storing the return value in a `String` — replace with
  `UUID` and the rest of the call site is unchanged.

  Corrected snippet:

  ```swift
  let token: UUID = Crossdeck.appAccountTokenForCurrentIdentity()
  let result = try await product.purchase(options: [
      .appAccountToken(token)
  ])
  ```

- **Doc-comment expanded to cover the anonymous-user / pre-identify
  case.** Three properties are now spelled out on the helper itself
  so integrators don't have to second-guess from release notes:

  1. **Never returns `nil`.** Even before the first `identify()`
     call, the helper lazy-mints a UUID and returns it. Purchases
     made while the SDK only knows the anonymous identity still get
     a stable token.
  2. **Not derived from `anonymousId`.** It is a fresh random UUID,
     independent of every other Crossdeck identifier. Rotating or
     resetting `anonymousId` does not affect it.
  3. **Persists across `identify()`.** When the developer later
     calls `identify("user_123")`, the SDK forwards the existing
     token alongside the alias request so the backend can bind
     `appAccountToken → developerUserId` without minting a new one.
     Past purchases stay attributed to the same chain.

  `reset()` is the only thing that wipes it, by design — the next
  user on the same device must not inherit the prior user's token.

## [1.5.0] — 2026-05-29

**Bank-grade Apple-rail Shape 2 fix.** The previous v1.4.x line
shipped an `appAccountToken` derivation that was a deterministic
function of `developerUserId`. That input is mutable across a
user's life (anonymous → logged in → account merge → SSO upgrade),
and Apple's transaction records are permanent. The instant
`developerUserId` changed, the SDK could no longer reproduce the
token Apple had stored — every renewal in that chain orphaned
silently. Bug count grew linearly with auto-tracked purchases.

This release makes the bug **impossible by construction** on the
happy path. The full design rationale is in
`Sources/Crossdeck/Identity.swift`'s `reset()` doc-comment.

**Added:**

- **`Crossdeck.appAccountTokenForCurrentIdentity() -> String`** —
  public helper. First call mints a fresh `UUID()`, persists it
  under the storage key `crossdeck.apple_app_account_token`, and
  returns the same value forever — independent of any `identify()`
  mutation. Wiped only on `reset()` (sign-out) so the next user on
  the same device receives a fresh token.

  Pass the result to StoreKit at purchase time:

  ```swift
  let token = Crossdeck.appAccountTokenForCurrentIdentity()
  let result = try await product.purchase(options: [
      .appAccountToken(token)
  ])
  ```

  Server-side, the binding `appAccountToken → developerUserId` is
  recorded via `identify()`'s alias request (the SDK attaches the
  persisted token automatically). Apple's later ASSN V2 webhook
  resolves via that binding, not the older implicit assumption
  that `appAccountToken == developerUserId`.

**Changed:**

- `PurchaseAutoTrack` and `Crossdeck.syncPurchases(...)` now read
  the persisted token via `Identity.ensureAppAccountTokenSync()`
  instead of deriving from `developerUserId`. Existing call sites
  upgrade automatically — no source changes required for consumers
  using the auto-track path.
- `AliasIdentityRequest` gains `appAccountToken: String?`. Every
  `identify()` and `identifyAndWait()` now carries the persisted
  token (when present) so the server records the binding before
  any later webhook arrives.

**Deprecated:**

- `AppAccountTokenDerivation.derive(developerUserId:)` — kept in
  the module to preserve the pinned cross-SDK oracle, but no
  longer called from the auto-track or `syncPurchases` paths.
  Header comment documents the failure walk so future contributors
  don't reintroduce the same trap by "simplifying" the persistence
  away.

**The actionability principle:**

Crossdeck's existing design philosophy ("classify, don't silently
drop") is right for events the developer can act on — cross-origin
`Script error.` events get captured with a `cross_origin` tag and
pointed at the CORS fix. It is NOT right for events the developer
cannot act on. Browser-extension errors, ad-blocker hits, and
Shape 2 orphans created by the prior derivation path all fall in
the latter category. This release applies the same principle to
the Apple-rail token: drop the deterministic-from-userId
derivation, persist a stable per-install UUID, and let the server
own the resolution via the recorded binding.

## [1.4.10] — 2026-05-27

`Crossdeck.reportContractFailure(_:)` is now single-fire to a
dedicated reliability endpoint instead of the customer's `track(_:)`
pipeline. Independent-controller flow per Privacy Policy §6;
schema-locked by `contracts/diagnostics/contract-failed-payload-
schema-lock.json`. `ContractFailureInput.extra` removed (schema-lock
forbids unbounded fields); `ContractFailureInput.deviceClass` added.

## [1.4.9] — 2026-05-27

`.crossdeckTap("Name")` — explicit tap-label bolt-on for SwiftUI
buttons whose label the auto-track can't reach on iOS 16+.

**Added:**

- **`View.crossdeckTap("Name", properties:)`** — public SwiftUI
  modifier that fires `element.clicked` via `.simultaneousGesture`
  (the button's own action still runs). One line per important
  CTA — matches the `.crossdeckScreen` pattern.

**Why this exists.** v1.4.7 added a walk-up-16 + descendant-search
to the UIWindow.sendEvent tap-capture path. That fixed SwiftUI
button labels on iOS 13–15 where Buttons rendered through UILabel
primitives. iOS 16+ SwiftUI uses the Metal text rendering pipeline
— `Button("Create Image")`'s text is drawn straight to a CALayer
and never lives on any `UILabel.text` or `UIView.accessibilityLabel`
the runtime can read. Apple's accessibility merge happens at the
SwiftUI virtual-view layer above UIKit; `UIView.accessibilityLabel`
stays nil on the rendered hierarchy. This is an Apple-imposed
limit, not a CrossDeck regression — Mixpanel, Amplitude, and
PostHog all ship a per-button modifier as the bank-grade answer.

**Usage:**

```swift
Button { generateImage() } label: { Text("Create Image") }
    .crossdeckTap("Create Image")
```

Composes onto any tappable View (Image with onTapGesture, custom
card layouts, list rows) — not just Button. Properties flow
through `cd.track` so coercion / size guard / cross-SDK label
resolution on the dashboard apply unchanged.

## [1.4.8] — 2026-05-27

Rename `enum Environment` → `enum CrossdeckEnvironment`. Structural
fix for the SwiftUI symbol collision — closes friction #19 deeper
than v1.4.4 caught it.

**Why:** v1.4.4 added `typealias CrossdeckEnvironment = Environment`
to disambiguate consumer code that imports both `SwiftUI` and
`Crossdeck`. That helped consumers but left the module-level public
`Environment` enum in scope inside the SDK itself. When v1.4.5
shipped `View.crossdeckScreen("Name")`, the new `ViewModifier`
contained `@Environment(\.crossdeck) private var cd` — and the
compiler resolved `Environment` to the SDK's enum (closer than
SwiftUI's), failing with `'Environment' cannot be used as an
attribute`. The SDK author shipped a public type that collided
with the most-used SwiftUI property wrapper for their own code.

**Fix:** rename the source enum to `CrossdeckEnvironment` and
remove the typealias entirely. There is no short form — the
qualified name is the only public name. Inside the SDK module
`@Environment(...)` now resolves to SwiftUI's wrapper
unambiguously, and consumer code that already follows the docs
(`let environment: CrossdeckEnvironment = .production`) is
unchanged.

**Breaking:** consumer code using `Environment.production` /
`Environment.sandbox` must use `CrossdeckEnvironment.production` /
`CrossdeckEnvironment.sandbox`. Pre-launch, no shipping consumer
relies on the short name — all install snippets and dogfood code
already use the qualified form.

## [1.4.7] — 2026-05-26

Auto-track tap labels now resolve on SwiftUI buttons — closes the
"Clicked an element" gap that buried real CTAs on the dashboard.

**Fixed:**

- The `UIWindow.sendEvent` tap-capture walked up only 4 ancestors
  looking for an `accessibilityLabel`. SwiftUI's button hosting tree
  is much deeper — `Button("Create Image") { … }` puts the merged
  accessibility label on a view 8–12 hops above the touched
  `Text` / `Image`. Bumped the walk-up to 16 ancestors so the label
  is reachable.
- New descendant-search fallback. SwiftUI's accessibility-merge
  model commonly puts the human-readable label on a SIBLING or a
  descendant of the hit-test target rather than an ancestor. When
  the ancestor walk-up returns nothing, the SDK now descends up to
  6 levels into the touched view's subtree looking for a `UILabel`
  with text or a view carrying an `accessibilityLabel`. First match
  wins — closest, shallowest descendant.
- New `textIndicatesPII` helper applies the same `password` /
  `card number` / `ssn` substring filter to descendant-found text
  as to ancestor accessibilityLabel — so a password field's visible
  text never lands on the wire.

Result: a SwiftUI `Button("Create Image") { … }` tap now ships
`element.clicked` with `accessibilityLabel = "Create Image"`, and
the Pages dashboard / live feed / per-person journey all render
**"Clicked 'Create Image'"** instead of "Clicked an element."

## [1.4.6] — 2026-05-26

SwiftUI hosting-controller denylist — the Pages dashboard no longer
fills up with framework noise.

**Fixed:**

- The auto-track UIViewController-appearance swizzle was leaking
  SwiftUI's internal hosting controllers (`PresentationHostingController<AnyView>`,
  `NavigationStackHostingController<AnyView>`, `UIKitNavigationController`)
  as `page.viewed` events. The existing denylist caught
  `UIHostingController` (top-level SwiftUI host) but missed the
  newer hosting machinery SwiftUI 5 / iOS 16+ added for sheets and
  NavigationStack. Result on a pure-SwiftUI app: the Pages dashboard
  filled with framework class names instead of the developer's real
  screens.
- New `screenViewClassSubstringDenylist` skips any class containing
  `HostingController` — catches all current and future SwiftUI host
  variants (including any prefixed by SwiftUI's mangled namespace).
- `UIKitNavigationController` (Apple's private UINavigationController
  subclass that backs NavigationStack) added to the exact-name
  denylist. It was firing on every navigation push and burying the
  developer's real screens with 11+ noise events per nav.

The right path for SwiftUI screen names remains `.crossdeckScreen("Name")`
(shipped in v1.4.5) — these denylist additions just stop the
fallback from producing noise when the modifier isn't applied yet.

## [1.4.5] — 2026-05-26

SwiftUI screen tracking — the iOS half of "log in tomorrow morning
and see what users tapped on yesterday."

**Added:**

- **`View.crossdeckScreen("Name")`** — public SwiftUI modifier that
  fires `page.viewed` with `{ screen, title }` properties when the
  view appears. SwiftUI's view tree hides class names from the
  iOS SDK's swizzle-based auto-track (the host is always
  `UIHostingController<…>`, denylisted for the right reason), so
  pure-SwiftUI apps emitted zero `page.viewed` events. One line
  per screen and the Pages dashboard populates the same way it
  does for a web app's URL list. Matches the pattern Mixpanel /
  Amplitude / PostHog ship on iOS; pairs with the Pages-backend
  change that groups by `screen` when `url` / `path` are absent.
  Properties are also forwarded through `cd.track(...)` so the
  standard coercion + size guard apply.

No behavioural change to existing UIKit auto-track — UIKit screens
keep firing `page.viewed` automatically via the
`UIViewController.viewDidAppear` swizzle (unchanged).

## [1.4.4] — 2026-05-26

Bank-grade SwiftUI integration polish. The Quickstart snippet now
pastes and runs end-to-end without the developer having to
hand-roll any wiring.

**Added:**

- **`EnvironmentValues.crossdeck`** — public SwiftUI environment key
  shipped by the SDK. Consumers can now write
  `ContentView().environment(\.crossdeck, cd)` at the App root and
  `@Environment(\.crossdeck) private var cd` inside any view, with
  zero `EnvironmentKey` boilerplate on the consumer side. Returns
  `Crossdeck?` so the optional-chain pattern at every call site
  keeps the host app crash-proof when the SDK didn't start. Lives
  under `#if canImport(SwiftUI)` so non-Apple-platform resolves
  still compile.
- **`CrossdeckEnvironment`** — public typealias for the SDK's
  `Environment` enum. Avoids the symbol collision every SwiftUI
  consumer hits the moment they `import Crossdeck` alongside
  `import SwiftUI` (SwiftUI's own `Environment` property wrapper).
  The bare `Environment` name stays exported for back-compat and
  keeps working unqualified in files that don't import SwiftUI.

**Changed:**

- Quickstart snippet (dashboard SDKs page → iOS) now uses
  `CrossdeckEnvironment` in place of bare `Environment`, so the
  copy-pasted boot code compiles cleanly inside a `@main App`
  file that also imports SwiftUI.

No behavioural change; both additions are purely ergonomic surface
that closes the "first dogfood paste-and-run" friction loop.

## [1.4.3] — 2026-05-26

Patch — second consumer compile fix surfaced by the same dogfood
project as v1.4.2. With v1.4.2's `idempotentReplay` field in place,
Swift's type-checker progressed further and pinned a separate
issue in `Crossdeck.init(options:)`:

The auto-tracked `purchases/sync` failure path's debug-logger call
passed `typed.statusCode as Any` into a `[String: String]` dict
literal. `debugLogger` is typed `(DebugSignal, [String: String]) ->
Void` (Stripe-style structured-payload contract — no `Any` smuggled
through the diagnostic surface). The dict literal rejected the
`Any` cast and emitted two cascading errors.

**Fixed:**

- `Crossdeck.swift:614` — replace `typed.statusCode as Any` with
  `typed.statusCode.map(String.init) ?? "n/a"`. `statusCode` is
  `Int?` — when present we stringify, when absent we emit `"n/a"`
  so the structured key is always populated.

No behavioural change; the debug payload now strictly conforms to
the typed shape the rest of the SDK already uses. Bundled
contracts (`Resources/contracts.json`) regenerated so `bundledIn`
stamps `@cross-deck/swift@1.4.3`.

## [1.4.2] — 2026-05-26

Patch — fix consumer compile error caused by a missing field on
`PurchaseResult`. Surfaced when the first iOS dogfood project pulled
v1.4.1 via SwiftPM and Xcode rejected the SDK source with two
cascading errors in `syncPurchases(...)`:

- `Value of type 'PurchaseResult' has no member 'idempotent_replay'`
- `Cannot convert value of type 'Any' to expected dictionary value
  type 'String'` (cascade — the Swift type-checker gives up on
  `[String: Any]` inference once a member resolves unknown)

**Fixed:**

- `PurchaseResult` gains `public let idempotentReplay: Bool?` with
  a `CodingKey` mapping the Swift-idiomatic camelCase property to
  the wire's `idempotent_replay` (snake_case, set by the backend's
  idempotency-response-cache middleware on cache-hit retries per
  the `idempotency-key-deterministic` contract).
- `syncPurchases(...)` now reads `result.idempotentReplay`. The
  analytics event property key stays `idempotent_replay` on the
  wire so dashboards joining `purchase.completed` across SDKs see
  the same key Web/Node/RN/Android already emit.

No new API surface; no behavioural change beyond the typed access
unlocking what the runtime was already receiving. Bundled
contracts (`Resources/contracts.json`) regenerated so `bundledIn`
stamps `@cross-deck/swift@1.4.2`.

## [1.4.1] — 2026-05-26

Patch — close the dogfood-surfaced gap on the
`per-user-cache-isolation` contract. v1.4.0 registered the contract
with `applies_to: ["web", "react-native"]` because Swift + Android
only shipped the in-memory wipe layer of the three-layer bank-grade
isolation — physical per-user storage keys + the clearAll-via-index
logout wipe were missing.

**Implemented in v1.4.1 (now in the contract's applies_to list):**
- `EntitlementCache.setUserKey(userId)` /
  `setUserKeySync(userId)` flip the persistent storage suffix to
  `sha256(userId)` so each user's blob lives under
  `crossdeck:entitlements:<hash>` — a user-switch on a shared
  device CANNOT cross-read prior user's data even if the
  in-memory wipe is somehow skipped.
- `EntitlementCache.clearAll()` reads the persisted suffix index
  and wipes every per-user slot — used by `Crossdeck.reset()` so
  a logout on a shared device cannot leave another user's
  entitlements readable.
- `Crossdeck.identify(userId)` calls `setUserKeySync(userId)`
  instead of `clearSync()`.
- `Crossdeck.reset()` (async) calls `clearAll()` instead of
  `clear()`.

No public API breakage; existing `identify()` / `reset()`
semantics upgrade from "in-memory only" to the full three-layer
contract.

## [1.4.0] — 2026-05-26

**Bank-grade reconciliation release.** 6-pillar KPMG-style audit
closed across SDK + backend. Every behavioural guarantee registered
in the monorepo's `contracts/` directory with a CI-enforced audit job.

### Added

- **`PurchaseAutoTrack` purchase durability.** `transaction.finish()`
  is now called STRICTLY inside the success branch of the backend
  sync. Pre-1.4.0 it fired regardless of outcome — a 5xx mid-process-
  death silently lost the purchase. Failed syncs persist to a new
  `PendingPurchaseQueue` (max 5 in-process retries, exp backoff
  30s/1m/5m/30m/2h).
- **Proper `appAccountToken` UUID conformance.** Derived from
  `developerUserId` via `AppAccountTokenDerivation` (UUID
  passthrough, else UUID v5 from URL namespace + `crossdeck:<id>`,
  else omit). Numeric StoreKit `originalTransactionId` now rides
  in its own dedicated wire field — pre-1.4.0 it was stuffed into
  the UUID-shaped `appAccountToken`, violating Apple's StoreKit
  contract.
- **Deterministic `Idempotency-Key` on `syncPurchases()`** — same
  JWS → same key. Cross-SDK parity oracle CI-pinned.
- **`PurchaseResult.idempotent_replay?: Bool`** — true when the
  backend replayed a cached response.
- **`purchase.completed` on every successful manual
  `syncPurchases()`** — funnel parity with auto-track.

### Changed (breaking)

- **`reset()` is now `async`**. Awaits identity / entitlements /
  super-properties / breadcrumbs clear before returning. New
  `isResetting` tombstone flips synchronously at entry; `isEntitled`
  honours it and returns false during the clear window — closes
  the race between a logout button firing reset() and the actor-
  internal clear completing. `resetSync()` exists for callers that
  cannot await.
- **`stop()` is now `async`**. Awaits `queue.persistAll()` and
  cancels stored boot + heartbeat Tasks. Pre-1.4.0 the Tasks ran
  fire-and-forget against actors of stopped clients. `stopSync()`
  exists for tests / deinit paths.
- **`CrossdeckErrorType.internalError` / `.configurationError`
  added; `.apiError` / `.unknown` deprecated** with `@available(*,
  deprecated, renamed:)`. Backend's `ApiErrorType` never emitted
  `"api_error"` or `"unknown_error"` on the wire — native pattern-
  matching on the deprecated cases only matched the SDK-synthesised
  fallback, never a real backend envelope. Use `.internalError`
  for 5xx responses.

### Added (continued)

- **`NSNotificationCenter` observer cleanup in `stop()`.** Pre-1.4.0
  every start→stop→start cycle leaked N orphan observers; each
  subsequent didEnterBackground fired N stacked queue.flush() against
  dead Crossdecks. Stored tokens, removed via
  `uninstallLifecycleObservers()`.
- **`ErrorCapture.shared.uninstall()` called in `stop()`.** Pre-1.4.0
  the global exception handler retained queue/identity/consent/
  breadcrumb actors of the stopped client; next uncaught exception
  shipped through dead actors.
- **Super-property merge order matches Web/Node/RN** — device <
  super < caller. Pre-1.4.0 Swift had it inverted (super < device <
  caller, so device clobbered super-properties).
- **Default event-queue flush interval is now 2000ms** (was 5000ms)
  — cross-SDK parity.

## [1.3.0] — 2026-05-25

Bank-grade identity lock — the Apple Bundle ID is now sent on
every request and enforced server-side, mirroring the Origin
lock the Web SDK has always had.

### Added — Apple Bundle ID identity claim

Every HTTP request the SDK fires now carries an
`X-Crossdeck-Bundle-Id` header sourced from
`Bundle.main.bundleIdentifier` — the OS-canonical ID Apple itself
uses for App Store identity.

The Crossdeck backend's `isBundleIdAllowed()` validator enforces
this against the bundleId stored on the iOS app key. Requests
without the header, or with a mismatched value, are rejected
with `403 / bundle_id_not_allowed`.

Bank-grade contract — same shape as the Web SDK's Origin lock:
- empty stored bundleId on the key → request rejected
- missing header on the request → request rejected
- exact-match required (case-sensitive — Apple's own convention)

### Migration

Customers must:
1. Bump SPM Dependency Rule to v1.3.0.
2. Rebuild + resubmit to App Store Connect.
3. Confirm `apps.ios.bundleId` is set on the project's iOS app
   in the Crossdeck dashboard (Apps → Bundle ID editor).

Apps shipped with v1.2.0 or earlier will start receiving 403s
once the backend enforcement deploys, because they don't send
the new header.

## [1.2.0] — 2026-05-25

Full bank-grade parity with the Web/Node/RN SDKs. v1.1.0 closed the
ergonomics gap (non-throwing track/identify/reset); v1.2.0 closes
every remaining gap that a serious customer would notice — auto-
tracking, performance vitals, mobile lifecycle, App Store privacy
manifest, and ambient signal modules.

### Added — Auto-tracking (sessions + screens + taps)

Cross-platform event vocabulary identical to Web SDK so a single
dashboard query returns Web + iOS + Android rows uniformly:

- `session.started` / `session.ended` with `sessionId` + `durationMs`.
  30-minute idle threshold matches GA4 / Mixpanel / Web SDK
  convention — a quick app-switch keeps the same session.
- `page.viewed` — fires automatically on every `UIViewController.viewDidAppear`
  via method swizzling. Skips framework hosts (UINavigationController,
  UIHostingController, _SwiftUI types). 250ms dedup window collapses
  push/pop animation double-fires.
- `element.clicked` — fires on every UIControl action (UIButton,
  UISwitch, UISlider, UISegmentedControl) AND on SwiftUI button taps
  via UIWindow.sendEvent capture. Captures accessibilityLabel,
  accessibilityIdentifier, class name, viewport coordinates.

Every event is enriched with the current `sessionId` so funnels work
without explicit instrumentation.

Privacy guardrails baked in:
- Secure text fields, accessibility labels containing `password` /
  `card` / `ssn` / `credit` / `cvv` / `pin` are skipped silently.
- Opt-out per element via `accessibilityIdentifier` containing
  `cd-noTrack` — Mixpanel-style convention familiar to iOS devs.
- 100ms tap-coalesce defeats React-Native-style double-fires.

Configurable via `CrossdeckOptions(autoTrack: .off)` for strict-
consent flows, or feature-grained:

```swift
CrossdeckOptions(
    autoTrack: AutoTrackConfig(
        sessions: true,
        screenViews: true,
        taps: false,  // disable tap autocapture only
        sessionResumeThresholdSeconds: 30 * 60
    )
)
```

### Added — PrivacyInfo.xcprivacy bundled in the SDK

Apple began enforcing the required-reason API manifest at App Store
Connect submit in May 2024. Without one, every embedding app is
rejected. Crossdeck now ships its own `PrivacyInfo.xcprivacy`
declaring:
- `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`
- `NSPrivacyAccessedAPICategorySystemBootTime` reason `35F9.1`
- `NSPrivacyTracking: false` (we do not link identity across third
  parties)

Consumer apps inherit the manifest automatically via SPM's resource
copy — no copy-paste, no one-off rejections.

### Added — MetricKit performance vitals (opt-in)

Mirrors Web SDK's `web-vitals.ts`. Set
`CrossdeckOptions(enablePerformanceMonitoring: true)` to receive:
- `perf.metrics` — daily aggregate (cold launch samples, resume
  samples, hang samples, peak memory, cumulative CPU).
- `perf.hang` — near-real-time UI-blocked diagnostics with
  hangDuration + metadata.
- `perf.cpu_exception` — sustained CPU spike diagnostics.
- `perf.disk_write_exception` — high-volume disk write diagnostics.
- `perf.crash_diagnostic` — MetricKit's process-fatal exception
  pipeline (complement to `NSSetUncaughtExceptionHandler`).

iOS 14+ / macOS 12+. Off by default — payload size is meaningful and
not every customer wants the signal.

### Added — Proactive network-edge flush

`NWPathMonitor` watches reachability. On `offline → online`
transitions, the event queue flushes immediately instead of waiting
for the next 5-second timer. Closes the latency gap on intermittent
connections (subway, airplane mode toggle).

ON by default via `CrossdeckOptions(enableReachabilityFlush: true)`.
iOS 12+ / macOS 10.14+.

### Added — Automatic StoreKit 2 purchase tracking (opt-in)

`CrossdeckOptions(automaticPurchaseTracking: true)` installs a
`Transaction.updates` AsyncSequence consumer. Every signed
transaction (purchase, restore, renewal, refund, family-shared)
flows to `/purchases/sync` via the same HTTP path `syncPurchases()`
uses AND fires a public funnel event:
- `purchase.completed` for new transactions
- `purchase.refunded` for revoked transactions (carries
  revocationReason)
- `purchase.unverified` for transactions Apple's signature check
  fails — fraud-signal candidate, never synced to backend

iOS 15+. Off by default because most apps already invoke
`syncPurchases()` from their own confirmation flow.

### Added — Deep-link + push interaction tracking helpers

Public API surface for the consumer to forward intent from their
SceneDelegate / UNUserNotificationCenter:
- `cd.trackDeepLink(url:source:)` — extracts UTM + click-id query
  parameters (gclid, fbclid, msclkid, ttclid, li_fat_id, twclid)
  as top-level properties. Fires `deeplink.opened`.
- `cd.trackPushReceived(userInfo:)` / `trackPushInteraction(userInfo:actionIdentifier:)`
  — surfaces marketing-platform IDs (campaign_id, message_id, etc.)
  without logging the alert body. Fires `push.received` /
  `push.interacted`.

### Fixed — `willTerminate` flush observer

Force-quit from the app switcher previously lost up to one batch
of queued events. v1.2.0 observes `UIApplication.willTerminateNotification`
and runs `queue.persistAll()` so the events land on disk before
the process dies. Next launch's queue rehydration ships them.

### Fixed — macOS / watchOS lifecycle parity

`Cmd+Q` on a Mac Catalyst or pure-AppKit Crossdeck client previously
fell off the lifecycle hook (only UIKit was wired). v1.2.0 adds
`NSApplication.willTerminateNotification` + `WKExtension.applicationDidEnterBackgroundNotification`
branches so every Apple OS the SDK targets has a persist-on-suspend
guarantee.

### Migration

None required. All new modules are additive or default-OFF where
they could be surprising. v1.1.0 call sites compile clean against
v1.2.0.

To benefit from auto-tracking, no code change — start using the
defaults. Customers who want to disable a specific signal:

```swift
CrossdeckOptions(
    // …
    autoTrack: AutoTrackConfig(taps: false),
    enableReachabilityFlush: false,
    enablePerformanceMonitoring: false,    // already default
    automaticPurchaseTracking: false        // already default
)
```

## [1.1.0] — 2026-05-25

Fire-and-forget API ergonomics — matches Mixpanel / Amplitude /
Sentry / Firebase Analytics iOS conventions. Dogfood feedback flagged
that requiring `try?` at every analytics call site is hostile in
Swift even though Web/Node/RN's `track()` throw — Swift's
compile-time enforcement makes the same shape user-hostile.

### Changed — `track`, `identify`, `reset` no longer throw

The three most-called methods now have non-throwing signatures.
Validation intent is unchanged; only the Swift-side signalling
mechanism is now idiomatic.

```diff
- try? cd?.track("paywall_seen")            // v1.0.x — Swift required try?
+ cd?.track("paywall_seen")                 // v1.1.0 — clean call site

- try? cd?.identify(userId: "user_123")     // v1.0.x
+ cd?.identify(userId: "user_123")          // v1.1.0

- try? cd?.reset()                          // v1.0.x
+ cd?.reset()                               // v1.1.0
```

Validation failures (empty event name, empty userId, called after
`stop()`) now:
- Log a warning via `debugLogger` with a `*_dropped` key naming
  the failure code.
- Trigger `assertionFailure` in Debug builds — loud during dev,
  silent no-op in Release. Aligns with Apple's first-party SDK
  conventions (UserDefaults, URLSession, OSLog: none throw on
  invalid arguments).
- Skip the actual work — the call becomes a no-op.

### Migration

This is a soft break. All v1.0.x callers still compile:
- `try? cd.track(...)` → compiles with a "no calls to throwing
  functions" warning. Drop the `try?` to clean up.
- `try cd.track(...)` inside a `do/catch` → compiles but the
  catch becomes unreachable (warning). Drop both `try` and
  the catch.
- Plain `cd.track(...)` (the v1.1.0 idiom) → compiles clean.

The non-throwing methods are:
- `track(_:properties:)`
- `identify(userId:email:traits:)`
- `reset()`

Still throwing (legitimate runtime failure modes):
- `Crossdeck.start(options:)` — config validation
- `identifyAndWait(userId:email:traits:)` — network round-trip + cdcust_ return
- `forget()` — network round-trip
- `getEntitlements()` — network round-trip
- `syncPurchases(rail:...)` — network round-trip
- `flush()`, `heartbeat()` — network round-trip

### Cross-SDK consistency

Web/Node/RN's `track()` keep their throwing signature because in
JavaScript, an uncaught throw propagates to the global error handler
without requiring `try`/`catch` at every call site. The platform
contract is "track validates input and signals failure for empty
name" — Swift's signalling is now language-idiomatic
(`assertionFailure` + debug log) instead of `throws`.

## [1.0.3] — 2026-05-25

Critical compile-fix release. v1.0.0–v1.0.2 declared `iOS(.v13)` in
`Package.swift` but `defaultDebugLogger()` used Apple's modern
`Logger` API, which is iOS 14 / macOS 11 / tvOS 14 / watchOS 7+.
Apps with a deployment target below those minimums failed to compile
the SDK with `'Logger' is only available in iOS 14.0 or newer`.

### Fixed

- `defaultDebugLogger()` now branches on availability. iOS 14+ uses
  `Logger` with structured `privacy: .public` interpolation; older
  OS versions fall back to the legacy `os_log` family (iOS 10+).
  Signal vocabulary identical; Console.app filtering on the
  `com.crossdeck.sdk` subsystem works on both paths.
- Package now compiles against any deployment target ≥ iOS 13 —
  same floor `Package.swift` has always claimed.

### Notes

- No API changes. Strictly additive availability gate.

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
