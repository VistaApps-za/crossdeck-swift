// Phase 5.1 + 5.2 contract tests — clean lifecycle teardown.
//
// Pre-v1.4.0:
//   - installLifecycleObservers discarded every addObserver return
//     value; start→stop→start leaked N orphan observers per
//     cycle. Each subsequent didEnterBackground fired N stacked
//     queue.flush() calls against dead Crossdecks.
//   - Crossdeck.stop() never called ErrorCapture.shared.uninstall();
//     the global exception handler retained queue/identity/consent/
//     breadcrumb actors of the stopped client, and the next
//     uncaught exception shipped through dead actors.

import XCTest
@testable import Crossdeck

final class LifecycleObserverCleanupTests: XCTestCase {

    private func makeOptions() -> CrossdeckOptions {
        CrossdeckOptions(
            appId: "app_test_observer",
            publicKey: "cd_pub_test_obs",
            environment: .sandbox,
            captureUncaughtExceptions: false,
            storage: MemoryStorage()
        )
    }

    func test_startedClient_capturesObserverTokens() {
        let cd = try! Crossdeck.start(options: makeOptions())
        defer { cd.stopSync() }
        // Platform-specific count: 3 observers on iOS (resign +
        // background + terminate), 2 on macOS / watchOS. We just
        // assert "more than zero" so the test stays portable across
        // every Package.swift target.
        XCTAssertGreaterThan(
            cd.lifecycleObserverTokens.count, 0,
            "start() must capture every NotificationCenter observer it installs"
        )
    }

    func test_stop_clearsAllObserverTokens() {
        let cd = try! Crossdeck.start(options: makeOptions())
        XCTAssertGreaterThan(cd.lifecycleObserverTokens.count, 0)

        cd.stopSync()

        XCTAssertEqual(
            cd.lifecycleObserverTokens.count, 0,
            "stop() MUST deregister every observer — pre-v1.4.0 leaked"
        )
    }

    func test_stop_calledTwice_idempotent() {
        // Defensive: double-stop must not crash and must leave the
        // token array empty.
        let cd = try! Crossdeck.start(options: makeOptions())
        cd.stopSync()
        cd.stopSync()
        XCTAssertEqual(cd.lifecycleObserverTokens.count, 0)
    }

    func test_consecutiveLifecycle_doesNotAccumulateAcrossInstances() {
        // Flagship Phase 5.1 invariant: a start→stop→start sequence
        // (each `start` returns a fresh instance) leaves only the
        // CURRENT instance's observers live. The prior instance's
        // observers must have been removed in its stop().
        let first = try! Crossdeck.start(options: makeOptions())
        let firstCount = first.lifecycleObserverTokens.count
        first.stopSync()
        XCTAssertEqual(first.lifecycleObserverTokens.count, 0)

        let second = try! Crossdeck.start(options: makeOptions())
        defer { second.stopSync() }
        XCTAssertEqual(
            second.lifecycleObserverTokens.count, firstCount,
            "Each new start MUST install exactly the same observer count, no accumulation"
        )
    }
}
