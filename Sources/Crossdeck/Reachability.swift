// Reachability — proactive flush when the network returns.
//
// Without this, an app that goes offline (subway, airplane mode,
// dead Wi-Fi) keeps accruing events but waits for the next 5-second
// flush timer after reconnect. With NWPathMonitor wired in, the
// instant the OS reports network connectivity, we kick the queue.
// Closes the dashboard latency gap on intermittent connections.
//
// Bank-grade contract:
//   * Public API requires iOS 12 / macOS 10.14 — gated to those.
//     Older targets get the SDK's existing timer-based flush.
//   * The monitor uses a low-priority background queue so it never
//     contends with UI work.
//   * Each Crossdeck instance has its own monitor — start/stop is
//     scoped to the instance lifetime, not the process.

import Foundation
import Network

/// Watches network reachability and fires a callback whenever the
/// path transitions to `.satisfied` (online). Use the callback to
/// trigger an event-queue flush.
@available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *)
final class Reachability: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let onReachable: @Sendable () -> Void
    private let lock = NSLock()
    private var wasReachable: Bool = false
    private var started: Bool = false

    init(onReachable: @escaping @Sendable () -> Void) {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.crossdeck.reachability", qos: .utility)
        self.onReachable = onReachable
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowReachable = (path.status == .satisfied)
            self.lock.lock()
            let prev = self.wasReachable
            self.wasReachable = nowReachable
            self.lock.unlock()
            // Edge transition off→on triggers a flush. We do NOT
            // fire on the FIRST notification when the app is already
            // online (no edge — the queue's start-time flush already
            // ships rehydrated events).
            if nowReachable && !prev {
                self.onReachable()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        monitor.cancel()
    }
}
