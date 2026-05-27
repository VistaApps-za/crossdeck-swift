// SwiftUI integration — Stripe-grade ergonomic surface for the
// SDK inside the View tree.
//
// Why this file exists:
//
//   Without it, every consumer of the SDK that wants to read the
//   `Crossdeck` instance inside a SwiftUI view has to hand-roll
//   the `EnvironmentKey` + `EnvironmentValues` extension before
//   the snippet's `.environment(\.crossdeck, cd)` line compiles.
//   That's the kind of pasted-snippet-doesn't-build paper cut
//   that makes a new dev bounce in the first five minutes. By
//   shipping the wiring at the SDK level, the snippet
//   becomes paste-and-run.
//
// Scope: SwiftUI is only available on Apple platforms where the
// framework can be imported. The whole file lives under
// `#if canImport(SwiftUI)` so Linux / server-side Swift builds of
// the SDK (which the v1 surface doesn't target but the package
// still resolves on) don't break on a missing module.

#if canImport(SwiftUI)

import SwiftUI

/// Internal key backing `EnvironmentValues.crossdeck`. The
/// default value is `nil` so a view that reads `\.crossdeck`
/// before any `.environment(\.crossdeck, ...)` modifier has been
/// applied gets a clear nil rather than a crash — same shape every
/// well-behaved SwiftUI SDK ships.
private struct CrossdeckEnvironmentKey: EnvironmentKey {
    static let defaultValue: Crossdeck? = nil
}

extension EnvironmentValues {
    /// The active `Crossdeck` instance for the current view subtree.
    ///
    /// Inject at the App root, right after `Crossdeck.start(...)`:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///     let cd: Crossdeck?
    ///     init() { cd = try? Crossdeck.start(options: ...) }
    ///     var body: some Scene {
    ///         WindowGroup {
    ///             ContentView().environment(\.crossdeck, cd)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Then read it from any view in the tree:
    ///
    /// ```swift
    /// struct PaywallView: View {
    ///     @Environment(\.crossdeck) private var cd
    ///     var body: some View {
    ///         Button("Buy") { cd?.track("paywall_cta_tapped") }
    ///     }
    /// }
    /// ```
    ///
    /// `Optional` because the SDK may have failed to start (bad key,
    /// missing app id, env mismatch). The optional-chain pattern at
    /// the call site keeps the host app crash-proof — telemetry
    /// becomes a no-op when the SDK isn't running, never a crash.
    public var crossdeck: Crossdeck? {
        get { self[CrossdeckEnvironmentKey.self] }
        set { self[CrossdeckEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Fire a `page.viewed` event when this view appears.
    ///
    /// SwiftUI screens don't surface a stable class name to the iOS
    /// SDK's swizzle-based auto-track (the host is always
    /// `UIHostingController<…>`, which the auto-track denylist
    /// rightly skips). This modifier is how a pure-SwiftUI app tells
    /// the dashboard "the user just landed on this screen" without
    /// going through `cd?.track(...)` by hand at every call site.
    ///
    /// Usage:
    ///
    /// ```swift
    /// CreateImageView()
    ///     .crossdeckScreen("Create Image")
    /// ```
    ///
    /// The event payload mirrors `page.viewed` on Web/UIKit so the
    /// Pages dashboard renders one unified list across surfaces.
    ///
    /// - Parameters:
    ///   - name: Human-readable screen name. Shown verbatim on the
    ///     Pages dashboard — keep it short and stable across releases
    ///     ("Create Image", not "CreateImageVC_v3"). Truncated to 128
    ///     chars to match the host-side title cap.
    ///   - properties: Optional extra properties to attach to the
    ///     event. Wired through `cd.track(...)` so the standard
    ///     coercion / size guard apply.
    public func crossdeckScreen(
        _ name: String,
        properties: [String: Any]? = nil
    ) -> some View {
        modifier(CrossdeckScreenModifier(name: name, extraProperties: properties))
    }

    /// Fire an `element.clicked` event when this view is tapped, with
    /// the human-readable label the dashboard's Top Actions + per-
    /// person journey will render.
    ///
    /// Why the bolt-on. The iOS SDK's UIWindow.sendEvent swizzle
    /// auto-captures touches, but on iOS 16+ SwiftUI renders Button
    /// text via the Metal text pipeline — the "Create Image" string
    /// is drawn straight to a CALayer and never lives on any
    /// `UILabel.text` or `UIView.accessibilityLabel` the runtime can
    /// read. The walk-up-16 + descendant-search added in v1.4.7
    /// works for iOS 13–15 SwiftUI but the iOS 16+ pipeline
    /// genuinely doesn't expose the label to UIView traversal.
    /// Industry standard fix — same shape Mixpanel, Amplitude, and
    /// PostHog ship for this Apple-imposed limit: one modifier per
    /// important CTA. The button's own action still runs (the tap
    /// gesture is attached via `simultaneousGesture`).
    ///
    /// Usage:
    ///
    /// ```swift
    /// Button { generateImage() } label: { Text("Create Image") }
    ///     .crossdeckTap("Create Image")
    /// ```
    ///
    /// Composes onto any tappable View — `Image`, `Text` with
    /// `.onTapGesture`, custom card layouts, list rows. Not just
    /// `Button`.
    ///
    /// - Parameters:
    ///   - name: Human-readable label. Renders on the dashboard as
    ///     "Clicked 'Name'". Truncated to 128 chars.
    ///   - properties: Optional extra properties (variant, plan
    ///     tier, A/B id) to attach to the event. Wired through
    ///     `cd.track(...)` so the standard coercion / size guard
    ///     apply.
    public func crossdeckTap(
        _ name: String,
        properties: [String: Any]? = nil
    ) -> some View {
        modifier(CrossdeckTapModifier(name: name, extraProperties: properties))
    }
}

private struct CrossdeckScreenModifier: ViewModifier {
    @Environment(\.crossdeck) private var cd
    let name: String
    let extraProperties: [String: Any]?

    func body(content: Content) -> some View {
        content.onAppear {
            guard let cd else { return }
            let trimmed = String(name.prefix(128))
            // Match the Web/UIKit `page.viewed` shape so the Pages
            // dashboard groups them uniformly. `screen` is the
            // canonical mobile-screen key the backend groups on
            // when url/path is absent; `title` mirrors what Web
            // auto-track sends so the dashboard's title-first
            // GA-style display has a value to render.
            var props: [String: Any] = [
                "screen": trimmed,
                "title": trimmed,
            ]
            if let extraProperties {
                for (k, v) in extraProperties where props[k] == nil {
                    props[k] = v
                }
            }
            cd.track("page.viewed", properties: props)
        }
    }
}

private struct CrossdeckTapModifier: ViewModifier {
    @Environment(\.crossdeck) private var cd
    let name: String
    let extraProperties: [String: Any]?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded { _ in
                guard let cd else { return }
                let trimmed = String(name.prefix(128))
                // Match the Web/UIKit `element.clicked` wire shape so
                // the dashboard's cross-SDK label resolver picks the
                // value up via the existing priority chain (label →
                // text → title → ariaLabel → accessibilityLabel →
                // contentDescription). `label` is the canonical key
                // — sets it directly so the Top Actions on the page
                // detail and the per-person journey both render
                // "Clicked 'Name'" verbatim.
                var props: [String: Any] = [
                    "label": trimmed,
                    "text": trimmed,
                ]
                if let extraProperties {
                    for (k, v) in extraProperties where props[k] == nil {
                        props[k] = v
                    }
                }
                cd.track("element.clicked", properties: props)
            }
        )
    }
}

#endif
