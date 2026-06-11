// Bounded ring buffer for context-leading-up-to-an-error.
//
// When an error is captured, we ship the last N breadcrumbs along
// with it so the consumer can reconstruct the path the user took to
// hit the failure. Bounded so a long-running app session can't
// accumulate unbounded memory; ring semantics so older context is
// dropped without a linear shift cost.
//
// Actor-isolated because both the SDK's own emit-points and the
// consumer's manual `addBreadcrumb` calls can fire from any thread
// (UI taps, background fetches, exception handler). Actor isolation
// gives us a single-writer guarantee without locks.

import Foundation

public enum BreadcrumbCategory: String, Sendable, Codable {
    case ui
    case http
    case lifecycle
    case error
    case identity
    case custom
}

public enum BreadcrumbLevel: String, Sendable, Codable {
    case debug
    case info
    case warning
    case error
}

public struct Breadcrumb: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let category: BreadcrumbCategory
    public let level: BreadcrumbLevel
    public let message: String
    public let data: [String: String]?

    public init(
        timestamp: Date = Date(),
        category: BreadcrumbCategory,
        level: BreadcrumbLevel = .info,
        message: String,
        data: [String: String]? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.data = data
    }
}

/// Default cap. 50 mirrors the web SDK — empirically deep enough
/// to capture a session-scope user journey, shallow enough to keep
/// the captured-error payload under typical HTTP limits.
public let defaultBreadcrumbCapacity: Int = 50

public actor Breadcrumbs {
    private var buffer: [Breadcrumb]
    private let capacity: Int

    public init(capacity: Int = defaultBreadcrumbCapacity) {
        // Clamp, never trap. `capacity` flows from the customer-settable
        // CrossdeckOptions.breadcrumbCapacity, so a 0 or negative value is
        // customer-reachable input — `precondition` would crash the host app
        // at Crossdeck.start() in a RELEASE build. Coerce to a safe minimum
        // instead (drop-and-sanitise, matching every other public surface).
        let safeCapacity = max(1, capacity)
        self.capacity = safeCapacity
        self.buffer = []
        self.buffer.reserveCapacity(safeCapacity)
    }

    public func add(_ crumb: Breadcrumb) {
        if buffer.count >= capacity {
            buffer.removeFirst(buffer.count - capacity + 1)
        }
        buffer.append(crumb)
    }

    public func snapshot() -> [Breadcrumb] {
        // Return a copy — callers should observe the state at the
        // moment the error fired, even if the buffer continues to
        // mutate afterwards.
        return buffer
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }
}
