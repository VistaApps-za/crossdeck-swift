// Input-safety contract for the public Crossdeck client surface.
//
// THE INVARIANT (uniform across Web / Node / React Native / Swift):
//   No public API ever crashes the host app, and invalid input never
//   reaches the wire. Invalid input is rejected at the call site — but the
//   SIGNALLING IDIOM is per-language and intentionally NOT uniform:
//     * Web / Node / React Native THROW a typed CrossdeckError
//       synchronously (a normal, catchable JS convention).
//     * Swift DROPS with a debug-log signal (fire-and-forget idiom,
//       matching its non-throwing public surface). identifyAndWait throws.
//   This Swift suite asserts the Swift half of the invariant: every public
//   fire-and-forget entry point survives empty/garbage input WITHOUT
//   throwing and WITHOUT trapping (no fatalError, assertionFailure, or
//   precondition).
//
// Why this file exists: the Swift SDK was never run by CI until the
// tag-triggered release pipeline. That let trap-on-input bugs ship —
// `track("")`/`identify("")` used assertionFailure (crashes Debug builds)
// and `breadcrumbCapacity: 0` used precondition (crashes RELEASE builds,
// i.e. the production app). This suite is the machine that proves a built
// SDK survives empty/garbage input on every public entry point. It is also
// run in release configuration in the release workflow, because precondition
// fires in -O while assertionFailure does not — so a debug-only gate would
// miss exactly the class of bug that reaches customers.
//
// If any call here traps, the test process aborts and the suite fails.
// "Survives" is the assertion; reaching the end of each test is the proof.

import XCTest
@testable import Crossdeck

final class PublicAPIInputSafetyTests: XCTestCase {

    private func makeClient(breadcrumbCapacity: Int = defaultBreadcrumbCapacity) -> Crossdeck {
        return try! Crossdeck.start(options: CrossdeckOptions(
            appId: "app_swift_inputsafety",
            publicKey: "cd_pub_test_inputsafety",
            environment: .sandbox,
            storage: MemoryStorage(),
            breadcrumbCapacity: breadcrumbCapacity
        ))
    }

    // The garbage bag: NaN, infinity, control chars, an oversize string, an
    // emoji, a nested collection, NSNull — the kinds of values a real app can
    // hand the SDK by accident.
    private var garbageProps: [String: Any] {
        [
            "nan": Double.nan,
            "inf": Double.infinity,
            "negInf": -Double.infinity,
            "control": "\u{0000}\u{0007}\u{001B}",
            "huge": String(repeating: "x", count: 200_000),
            "emoji": "🧨💥🔥",
            "nested": ["a": ["b": ["c": [1, 2, 3]]]],
            "null": NSNull(),
            "": "empty-key",
        ]
    }

    // MARK: - Construction with garbage config must not trap

    func test_start_withZeroBreadcrumbCapacity_doesNotTrap() {
        // precondition(capacity > 0) used to crash here in BOTH debug and
        // release. Clamped now — must construct cleanly.
        let cd = makeClient(breadcrumbCapacity: 0)
        defer { cd.stopSync() }
        cd.captureMessage("after zero-capacity construction")
    }

    func test_start_withNegativeBreadcrumbCapacity_doesNotTrap() {
        let cd = makeClient(breadcrumbCapacity: -100)
        defer { cd.stopSync() }
        cd.captureMessage("after negative-capacity construction")
    }

    // MARK: - Every fire-and-forget API survives empty + garbage input

    func test_track_emptyAndGarbage_doesNotThrowOrTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.track("")
        cd.track("", properties: garbageProps)
        cd.track(String(repeating: "n", count: 100_000), properties: garbageProps)
        cd.track("🧨", properties: ["amount": Double.nan])
        cd.track("\u{0000}control")
    }

    func test_identify_emptyAndGarbage_doesNotThrowOrTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.identify(userId: "")
        cd.identify(userId: "", email: "", traits: garbageProps)
        cd.identify(userId: "u_1", email: "not-an-email", traits: garbageProps)
        cd.identify(userId: String(repeating: "u", count: 100_000))
    }

    func test_superProperties_emptyAndGarbage_doesNotTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.registerSuperProperty("", "")
        cd.registerSuperPropertyOnce("", "")
        cd.registerSuperProperty("k", String(repeating: "v", count: 100_000))
        cd.unregisterSuperProperty("")
        cd.unregisterSuperProperty("never-registered")
    }

    func test_tagsAndContext_emptyAndGarbage_doesNotTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.setTag("", "")
        cd.setTags([:])
        cd.setTags(["": "", "k": String(repeating: "v", count: 100_000)])
        cd.setContext("", [:])
        cd.setContext("ctx", ["": ""])
    }

    func test_messagesAndBreadcrumbs_emptyAndGarbage_doesNotTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.captureMessage("")
        cd.captureMessage("", level: .error)
        cd.captureMessage(String(repeating: "m", count: 100_000), level: .warning)
        cd.addBreadcrumb(Breadcrumb(category: .custom, message: ""))
        cd.addBreadcrumb(Breadcrumb(category: .custom, level: .debug, message: "🧨", data: ["": ""]))
    }

    func test_entitlementQueries_emptyKey_doesNotTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        XCTAssertFalse(cd.isEntitled(""))
        _ = cd.entitlementStatus("")
        _ = cd.activeEntitlementKeys()
        _ = cd.entitlementsForCurrentCustomer()
    }

    func test_resetAndConsent_doesNotTrap() {
        let cd = makeClient()
        defer { cd.stopSync() }
        cd.resetSync()
        cd.setConsent(ConsentState(analytics: false, errors: false))
        cd.setScrubPII(false)
        cd.setScrubPII(true)
    }

    // MARK: - After stop(), every call is a defined no-op (not a crash)

    func test_allCalls_afterStop_dropSilently() {
        let cd = makeClient()
        cd.stopSync()
        cd.stopSync() // idempotent
        cd.track("after_stop", properties: garbageProps)
        cd.identify(userId: "after_stop")
        cd.registerSuperProperty("k", "v")
        cd.setTag("k", "v")
        cd.captureMessage("after_stop")
        cd.addBreadcrumb(Breadcrumb(category: .custom, message: "after_stop"))
        cd.resetSync()
        XCTAssertFalse(cd.isEntitled("pro"))
    }
}
