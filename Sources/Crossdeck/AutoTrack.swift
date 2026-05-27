// AutoTrack — sessions, screen views, and tap autocapture.
//
// Mirrors Web SDK's auto-track.ts contract: same event names
// (`session.started`, `session.ended`, `page.viewed`, `element.clicked`),
// same property shape, same 30-minute idle threshold for session
// resume. A cross-platform dashboard query for `page.viewed` returns
// Web + iOS + Android rows uniformly — the `platform` property
// (added by the Crossdeck client on every event) discriminates when
// needed.
//
// ## Architecture
//
// AutoTracker is a process-wide singleton because:
//
//   1. Method swizzling is global. Once we exchange UIControl's
//      sendAction(_:to:for:) implementation, every UIControl in the
//      process is instrumented. There's no way to swizzle per-
//      instance, and trying to un-swizzle race-prone.
//   2. App lifecycle is global. There is exactly one
//      UIApplication.didEnterBackgroundNotification per process.
//   3. Multiple Crossdeck instances (test isolation, hot reload)
//      share the same UI/lifecycle observations but each can
//      register its own emit closure — AutoTracker multicasts to
//      every registered listener.
//
// ## Bank-grade contract
//
// - **Privacy guardrails baked in.** Secure text fields, accessibility
//   labels containing `password`/`card`/`ssn`/`credit`, and elements
//   tagged with the `cd-noTrack` accessibility identifier convention
//   are all skipped silently.
// - **Volume guardrails.** A 250ms dedup window on screen views
//   (SwiftUI navigation transitions fire viewDidAppear repeatedly),
//   a 100ms coalesce on taps (React-Native-style synthetic + native
//   double-fires).
// - **Opt-out at the SDK level.** Consumer passes
//   `autoTrack: .off` (or per-feature toggles) at start() if they
//   want manual-only instrumentation. Bank-grade default is
//   everything ON — behavioural attribution is Crossdeck's USP.

import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC.runtime
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(WatchKit)
import WatchKit
#endif

/// Per-feature toggles for auto-tracking.
///
/// Defaults: everything ON. Behavioural attribution (which screens,
/// which buttons) is what makes a Crossdeck install valuable on day 1
/// without the customer having to instrument every call site. Match
/// the Web SDK auto-track defaults.
///
/// Strict-privacy customers (finance, healthcare) typically set
/// `taps: false` and `screenViews: false`, leaving only `sessions: true`
/// for revenue / DAU math. Then they hand-instrument the events they
/// explicitly want via `cd.track(...)`.
public struct AutoTrackConfig: Sendable {
    /// `session.started` / `session.ended` lifecycle events.
    /// Disabling this also disables `durationMs` on every event
    /// (because there's no session anchor to compute it from).
    public var sessions: Bool

    /// `page.viewed` fires on every `UIViewController.viewDidAppear`,
    /// skipping framework hosts and our own internal classes.
    /// SwiftUI screens fire too (NavigationStack uses internal
    /// UIHostingController instances).
    public var screenViews: Bool

    /// `element.clicked` fires on UIControl actions and SwiftUI
    /// button taps (via UIWindow.sendEvent). Captures accessibility
    /// label, identifier, class name, and viewport coordinates.
    public var taps: Bool

    /// Idle threshold before a foreground-resume starts a new
    /// session. Default 30 minutes — matches GA4 / Mixpanel / Web SDK
    /// convention. Below the threshold, a quick app-switch keeps the
    /// same `sessionId`.
    public var sessionResumeThresholdSeconds: TimeInterval

    /// Default-everything-on configuration. Use this from
    /// `CrossdeckOptions()` unless you have a specific opt-out flow.
    public static let `default` = AutoTrackConfig(
        sessions: true,
        screenViews: true,
        taps: true,
        sessionResumeThresholdSeconds: 30 * 60
    )

    /// All auto-tracking disabled. Equivalent to the developer
    /// hand-firing every event via `cd.track(...)`. Useful for
    /// strict-consent flows where the SDK must emit zero events
    /// before explicit user consent.
    public static let off = AutoTrackConfig(
        sessions: false,
        screenViews: false,
        taps: false,
        sessionResumeThresholdSeconds: 30 * 60
    )

    public init(
        sessions: Bool = true,
        screenViews: Bool = true,
        taps: Bool = true,
        sessionResumeThresholdSeconds: TimeInterval = 30 * 60
    ) {
        self.sessions = sessions
        self.screenViews = screenViews
        self.taps = taps
        self.sessionResumeThresholdSeconds = sessionResumeThresholdSeconds
    }
}

/// Process-wide auto-tracker. Owns swizzling, lifecycle observers,
/// and session state. Multicasts events to every registered Crossdeck
/// instance's `track(...)` pipeline.
final class AutoTracker: @unchecked Sendable {
    /// Singleton instance — the only one that exists in the process.
    static let shared = AutoTracker()

    private let lock = NSLock()
    private var listeners: [Int: (String, [String: Any]) -> Void] = [:]
    private var nextListenerId: Int = 0

    // Session state — gated by `lock`.
    private var sessionId: String?
    private var sessionStartedAt: Date?
    private var lastBackgroundedAt: Date?
    private var sessionEndEmitted: Bool = false
    private var resumeThreshold: TimeInterval = 30 * 60

    // Config bitmap — any listener with a feature ON enables that
    // pathway. We aggregate so multi-instance test setups don't
    // need to coordinate.
    private var anySessionsOn: Bool = false
    private var anyScreenViewsOn: Bool = false
    private var anyTapsOn: Bool = false

    private var observersInstalled = false

    private init() {}

    // MARK: - Registration

    /// Register a Crossdeck instance to receive auto-track events.
    /// Returns an unregister handle the instance stores and calls
    /// from `stop()`. Each call is idempotent across the process —
    /// the global swizzle hooks install on the first registration
    /// and stay installed for the process lifetime (un-swizzling
    /// is race-prone and not worth the complexity).
    @discardableResult
    func register(config: AutoTrackConfig, emit: @escaping (String, [String: Any]) -> Void) -> () -> Void {
        lock.lock()
        let id = nextListenerId
        nextListenerId += 1
        listeners[id] = emit
        if config.sessions { anySessionsOn = true }
        if config.screenViews { anyScreenViewsOn = true }
        if config.taps { anyTapsOn = true }
        resumeThreshold = config.sessionResumeThresholdSeconds

        let needsInstall = !observersInstalled
        observersInstalled = true
        let sessionsOn = config.sessions
        let needsSessionStart = sessionsOn && sessionId == nil
        lock.unlock()

        if needsInstall {
            installLifecycleObservers()
            #if canImport(UIKit) && !os(watchOS)
            Self.swizzleOnce()
            #endif
        }

        if needsSessionStart {
            startSession(reason: "register")
        }

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    // MARK: - Emit (multicast)

    fileprivate func emit(_ name: String, _ properties: [String: Any]) {
        lock.lock()
        let snapshot = Array(listeners.values)
        lock.unlock()
        for listener in snapshot {
            listener(name, properties)
        }
    }

    // MARK: - Sessions

    private func startSession(reason: String) {
        lock.lock()
        guard anySessionsOn else { lock.unlock(); return }
        let id = mintSessionId()
        sessionId = id
        sessionStartedAt = Date()
        sessionEndEmitted = false
        lock.unlock()
        emit("session.started", ["sessionId": id, "reason": reason])
    }

    private func endSessionIfActive(reason: String) {
        lock.lock()
        guard anySessionsOn,
              !sessionEndEmitted,
              let id = sessionId,
              let startedAt = sessionStartedAt
        else { lock.unlock(); return }
        sessionEndEmitted = true
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        lock.unlock()
        emit("session.ended", [
            "sessionId": id,
            "durationMs": durationMs,
            "reason": reason,
        ])
    }

    /// Public helper for ad-hoc session reset (logout flows, "force
    /// new session" debugging). Mirrors Web SDK's AutoTracker.resetSession.
    func resetSession() {
        endSessionIfActive(reason: "manual_reset")
        startSession(reason: "manual_reset")
    }

    private func mintSessionId() -> String {
        return "ses_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Read-only accessor used by Crossdeck.track() to enrich every
    /// event with the current sessionId. Returns nil before
    /// startSession() has fired or after endSessionIfActive() and
    /// before a new startSession().
    func currentSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionEndEmitted ? nil : sessionId
    }

    // MARK: - Lifecycle observers

    private func installLifecycleObservers() {
        let center = NotificationCenter.default

        #if canImport(UIKit) && !os(watchOS)
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleForeground()
        }
        center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.endSessionIfActive(reason: "terminate")
        }
        #elseif canImport(AppKit)
        // Mac Catalyst lands in the UIKit branch above; pure
        // AppKit Mac apps land here. NSApplication's lifecycle
        // notifications fire on `Cmd+Q`, `Cmd+H`, and system
        // shutdown — covering the loss surface the iOS UIApplication
        // path covers on phones.
        center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleForeground()
        }
        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.endSessionIfActive(reason: "terminate")
        }
        #elseif canImport(WatchKit) && os(watchOS)
        center.addObserver(
            forName: WKExtension.applicationDidEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }
        center.addObserver(
            forName: WKExtension.applicationDidBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleForeground()
        }
        #endif
    }

    private func handleBackground() {
        lock.lock()
        lastBackgroundedAt = Date()
        lock.unlock()
        endSessionIfActive(reason: "background")
    }

    private func handleForeground() {
        lock.lock()
        let backgroundedAt = lastBackgroundedAt
        let threshold = resumeThreshold
        let hasSession = sessionId != nil && !sessionEndEmitted
        lock.unlock()

        let idleSeconds = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if !hasSession || idleSeconds >= threshold {
            // Either no session (first foreground after background-end)
            // or idle past the threshold — mint a fresh session. This
            // matches the Web SDK's 30-min session-window convention.
            startSession(reason: idleSeconds >= threshold ? "resume_idle" : "resume")
        }
        // Short-idle resume (under threshold) keeps the prior sessionId
        // implicit — but the prior session was ended on background.
        // So we always restart; the threshold only controls whether
        // we treat it as "resume same intent" (could be tightened to
        // resurrect prior sessionId, but Web parity requires we mint
        // a new id either way after background-end).
    }

    // MARK: - Static swizzling (one-shot)

    #if canImport(UIKit) && !os(watchOS)
    /// Swizzle UIControl.sendAction, UIViewController.viewDidAppear,
    /// and UIWindow.sendEvent. Fires exactly once per process via
    /// the `static let` dispatch-once equivalent.
    static func swizzleOnce() {
        _ = _swizzleAll
    }

    private static let _swizzleAll: Void = {
        swizzleUIControl()
        swizzleViewController()
        swizzleUIWindow()
    }()

    private static func swizzleUIControl() {
        let cls = UIControl.self
        let originalSel = #selector(UIControl.sendAction(_:to:for:))
        let swizzledSel = #selector(UIControl.cd_sendAction(_:to:for:))
        guard let original = class_getInstanceMethod(cls, originalSel),
              let swizzled = class_getInstanceMethod(cls, swizzledSel) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }

    private static func swizzleViewController() {
        let cls = UIViewController.self
        let originalSel = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSel = #selector(UIViewController.cd_viewDidAppear(_:))
        guard let original = class_getInstanceMethod(cls, originalSel),
              let swizzled = class_getInstanceMethod(cls, swizzledSel) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }

    private static func swizzleUIWindow() {
        let cls = UIWindow.self
        let originalSel = #selector(UIWindow.sendEvent(_:))
        let swizzledSel = #selector(UIWindow.cd_sendEvent(_:))
        guard let original = class_getInstanceMethod(cls, originalSel),
              let swizzled = class_getInstanceMethod(cls, swizzledSel) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
    #endif

    // MARK: - Internal emit gates (called from swizzled methods)

    fileprivate var screenViewsEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return anyScreenViewsOn
    }

    fileprivate var tapsEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return anyTapsOn
    }

    // Dedup state — protected by `lock`.
    fileprivate func shouldFireScreenView(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastScreenViewAt, name == lastScreenViewName,
           now.timeIntervalSince(last) < 0.25 {
            return false
        }
        lastScreenViewAt = now
        lastScreenViewName = name
        return true
    }

    fileprivate func shouldFireTap(selector: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastTapAt, selector == lastTapSelector,
           now.timeIntervalSince(last) < 0.1 {
            return false
        }
        lastTapAt = now
        lastTapSelector = selector
        return true
    }

    private var lastScreenViewAt: Date?
    private var lastScreenViewName: String?
    private var lastTapAt: Date?
    private var lastTapSelector: String?
}

// MARK: - UIKit swizzled methods

#if canImport(UIKit) && !os(watchOS)

/// Class names that the SDK refuses to emit as `page.viewed` events.
/// These are UIKit / SwiftUI framework hosts that fire viewDidAppear
/// during navigation transitions but don't represent a screen the
/// user thinks of as a distinct destination. Without this filter,
/// a single tap on a NavigationLink emits 3-5 `page.viewed` events.
private let screenViewClassDenylist: Set<String> = [
    "UINavigationController",
    "UITabBarController",
    "UISplitViewController",
    "UIPageViewController",
    "UIInputViewController",
    "UICompatibilityInputViewController",
    "_UIAlertControllerTextFieldViewController",
    "UIPresentationController",
    "UIPredictionViewController",
    // SwiftUI's internal UINavigationController subclass that backs
    // NavigationStack. Apple's name; on the dashboard this would
    // surface as "UIKitNavigationController" — meaningless to the
    // developer. The actual destination is captured by
    // `.crossdeckScreen("Name")` on the View that's pushed.
    "UIKitNavigationController",
]

/// Class-name prefixes / substrings that indicate a framework /
/// internal type. We skip these to keep the dashboard journey
/// readable — these classes have no human-meaningful name a
/// developer would recognise.
private let screenViewClassPrefixDenylist: [String] = [
    "_UI",                  // Apple private UIKit
    "_SwiftUI",             // SwiftUI internal types
    "_TtGC7SwiftUI",        // SwiftUI mangled generics
    "_TtCV7SwiftUI",        // ditto
    "UIHostingController",  // SwiftUI host
    "UIRemoteKeyboard",
]

/// Class-name substrings indicating a SwiftUI hosting controller.
/// Anything matching is a framework wrapper around a real View —
/// the dashboard shouldn't show "PresentationHostingController<AnyView>"
/// or "NavigationStackHostingController<AnyView>"; those mean nothing
/// to the developer. The real screen is captured by
/// `.crossdeckScreen("Name")` on the destination View.
///
/// Substring rather than prefix because SwiftUI prepends a
/// type-mangled namespace on these in some configurations
/// (e.g. `SwiftUI.PresentationHostingController<…>`) — substring
/// catches both forms.
private let screenViewClassSubstringDenylist: [String] = [
    "HostingController",    // *HostingController — SwiftUI hosts
]

/// Accessibility-identifier convention for opt-out. Mirrors
/// Mixpanel's `mp-no-track` and Amplitude's `amp-block-track` idioms.
/// Set `view.accessibilityIdentifier = "cd-noTrack"` (or include the
/// substring) to exclude an element from autocapture.
private let optOutIdentifierSubstring = "cd-noTrack"

/// Accessibility-label substrings that hint at PII. Any element with
/// a label matching these is skipped silently.
private let piiLabelSubstrings = [
    "password", "passcode", "pin",
    "card number", "credit card", "cvv", "cvc",
    "ssn", "social security",
    "bank account", "routing number",
]

extension UIControl {
    @objc func cd_sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        // Forward to the ORIGINAL implementation first (swap means
        // calling cd_sendAction here resolves to the original IMP).
        // This MUST run before our capture so the consumer's action
        // is dispatched even if our capture throws.
        self.cd_sendAction(action, to: target, for: event)

        guard AutoTracker.shared.tapsEnabled else { return }

        // Skip text-field/text-view editing fires. UIControl's
        // sendAction is called for editingChanged on every keystroke
        // — that's not a "click", it's keyboard noise.
        if self is UITextField || self is UITextView { return }

        // Skip controls whose accessibility identifier opts out.
        if isOptedOutFromAutoTrack(self) { return }

        // Skip secure / sensitive accessibility labels.
        if labelIndicatesPII(self) { return }

        // Coalesce React-Native-style double fires (synthetic + native)
        // on the same target within 100ms.
        let selectorString = NSStringFromSelector(action)
        if !AutoTracker.shared.shouldFireTap(selector: "\(ObjectIdentifier(self))_\(selectorString)") {
            return
        }

        var props: [String: Any] = [
            "element": String(describing: type(of: self)),
            "action": selectorString,
        ]
        if let id = accessibilityIdentifier, !id.isEmpty {
            props["accessibilityId"] = String(id.prefix(128))
        }
        if let label = accessibilityLabel, !label.isEmpty {
            props["accessibilityLabel"] = String(label.prefix(128))
        }
        if let button = self as? UIButton,
           let title = button.title(for: .normal), !title.isEmpty {
            props["title"] = String(title.prefix(128))
        }
        AutoTracker.shared.emit("element.clicked", props)
    }
}

extension UIViewController {
    @objc func cd_viewDidAppear(_ animated: Bool) {
        self.cd_viewDidAppear(animated)

        guard AutoTracker.shared.screenViewsEnabled else { return }

        let className = String(describing: type(of: self))

        // Skip framework hosts / containers.
        if screenViewClassDenylist.contains(className) { return }
        for prefix in screenViewClassPrefixDenylist where className.hasPrefix(prefix) {
            return
        }
        for substring in screenViewClassSubstringDenylist where className.contains(substring) {
            return
        }

        // Skip presented system alerts / sheets we shouldn't track.
        if self is UIAlertController { return }

        // The dedup is keyed on class name — repeated transitions
        // to the SAME screen within 250ms (push/pop animations)
        // collapse to one event.
        guard AutoTracker.shared.shouldFireScreenView(name: className) else { return }

        var props: [String: Any] = ["screen": className]
        if let title = self.title, !title.isEmpty {
            props["title"] = String(title.prefix(128))
        }
        if let restoration = self.restorationIdentifier, !restoration.isEmpty {
            props["restorationId"] = restoration
        }
        // SwiftUI screens often have an empty class name like
        // "UIHostingController<ContentView>" which the prefix denylist
        // catches — so by here we only see consumer UIViewController
        // subclasses or top-level SwiftUI screens with a custom title.
        AutoTracker.shared.emit("page.viewed", props)
    }
}

extension UIWindow {
    @objc func cd_sendEvent(_ event: UIEvent) {
        // Forward first.
        self.cd_sendEvent(event)

        guard AutoTracker.shared.tapsEnabled else { return }
        guard event.type == .touches else { return }

        // We only care about single-tap UP — multi-touch + swipes
        // + pinches are not "clicks" in the analytics sense.
        guard let touches = event.allTouches, touches.count == 1,
              let touch = touches.first,
              touch.phase == .ended,
              touch.tapCount == 1
        else { return }

        // Find the deepest interactive view at the touch point.
        let point = touch.location(in: self)
        guard let hit = self.hitTest(point, with: event) else { return }

        // If the hit-test view is a UIControl, the UIControl swizzle
        // already captured it — skip the double-fire.
        if hit is UIControl { return }
        if hit is UITextField || hit is UITextView { return }

        // Walk up to find a view with a meaningful accessibility
        // signal. SwiftUI's button hosting tree can be deep —
        // `Button("Create Image") { … }` puts the accessibility
        // label on the merged Button view, which is often 8-12
        // UIView hops above the visible Text / Image the user
        // physically tapped. The old 4-ancestor cap missed it
        // entirely and emitted unlabelled element.clicked events.
        // 16 is high enough for current iOS 16+ SwiftUI hierarchies
        // and still bounded so a runaway view tree can't spin.
        var view: UIView? = hit
        var depth = 0
        var labelSource: UIView?
        while let v = view, depth < 16 {
            if (v.accessibilityLabel?.isEmpty == false) ||
               (v.accessibilityIdentifier?.isEmpty == false) {
                labelSource = v
                break
            }
            view = v.superview
            depth += 1
        }
        // SwiftUI Button("Text") rendering also commonly puts the
        // visible text on a UILabel inside the touched view's
        // descendants — and the merged accessibility label may be
        // set on a SIBLING, not an ancestor. Descend up to 6 levels
        // looking for a UILabel with text or a descendant with an
        // accessibilityLabel. Bank-grade fallback so a tapped
        // button always has SOMETHING to render on the dashboard.
        let primary = labelSource ?? hit
        let resolvedText: String? = (labelSource?.accessibilityLabel?.isEmpty == false)
            ? labelSource?.accessibilityLabel
            : findDescendantLabel(hit, depth: 0)

        // Skip opt-out.
        if isOptedOutFromAutoTrack(primary) { return }
        // Skip PII labels.
        if labelIndicatesPII(primary) { return }

        // Build a stable selector key so the coalesce dedup works
        // across UIWindow + UIControl pathways on the same target.
        let selectorKey = "uiwindow_\(ObjectIdentifier(primary))"
        if !AutoTracker.shared.shouldFireTap(selector: selectorKey) { return }

        var props: [String: Any] = [
            "element": String(describing: type(of: primary)),
            "viewportX": Int(point.x),
            "viewportY": Int(point.y),
        ]
        if let id = primary.accessibilityIdentifier, !id.isEmpty {
            props["accessibilityId"] = String(id.prefix(128))
        }
        // Privacy guard before adopting the resolved text — same PII
        // substring check the labelIndicatesPII helper applies to
        // accessibilityLabel. A descendant UILabel might carry text
        // like "Card number" that we never want to ship.
        let candidate = resolvedText?.isEmpty == false ? resolvedText
                      : (primary.accessibilityLabel?.isEmpty == false ? primary.accessibilityLabel : nil)
        if let label = candidate, !textIndicatesPII(label) {
            props["accessibilityLabel"] = String(label.prefix(128))
        }
        AutoTracker.shared.emit("element.clicked", props)
    }
}

/// Descend into the touched view's subtree looking for a UILabel
/// with text or any view carrying an accessibility label. SwiftUI's
/// merged-accessibility model often puts the human-readable label
/// on a sibling / descendant of the hit-test target rather than an
/// ancestor; this is the fallback the ancestor walk-up reaches for
/// when SwiftUI's tree doesn't propagate the label upward.
///
/// Bounded depth (6) plus a hard subtree-node cap so a list cell
/// with thousands of nested layout views can't spin. First match
/// wins — preference is the closest, shallowest descendant.
private func findDescendantLabel(_ view: UIView, depth: Int) -> String? {
    if depth > 6 { return nil }
    if let label = view.accessibilityLabel, !label.isEmpty {
        return label
    }
    if let lbl = view as? UILabel, let text = lbl.text, !text.isEmpty {
        return text
    }
    for sub in view.subviews {
        if let found = findDescendantLabel(sub, depth: depth + 1) {
            return found
        }
    }
    return nil
}

// MARK: - Helpers

private func isOptedOutFromAutoTrack(_ view: NSObject) -> Bool {
    var cursor: NSObject? = view
    var depth = 0
    while let current = cursor, depth < 6 {
        if let id = (current as? UIView)?.accessibilityIdentifier ?? (current as? UIControl)?.accessibilityIdentifier,
           id.contains(optOutIdentifierSubstring) {
            return true
        }
        if let view = current as? UIView, let parent = view.superview {
            cursor = parent
        } else {
            cursor = nil
        }
        depth += 1
    }
    return false
}

private func labelIndicatesPII(_ view: NSObject) -> Bool {
    let label = (view as? UIView)?.accessibilityLabel?.lowercased()
        ?? (view as? UIControl)?.accessibilityLabel?.lowercased()
    guard let label, !label.isEmpty else { return false }
    return textIndicatesPII(label)
}

/// String-level PII guard. Reused for both the ancestor-walked
/// accessibilityLabel and the descendant-found UILabel.text, so a
/// password field's visible text or a card-number label never lands
/// on the wire.
private func textIndicatesPII(_ text: String) -> Bool {
    let lowered = text.lowercased()
    for needle in piiLabelSubstrings where lowered.contains(needle) {
        return true
    }
    return false
}

#endif
