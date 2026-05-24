// swift-tools-version: 5.9
//
// Crossdeck — verified subscriptions, entitlements, error capture,
// and product telemetry across iOS / iPadOS / macOS / tvOS / watchOS
// in one Swift Package. Mirrors the public API surface of
// @cross-deck/web + @cross-deck/node + @cross-deck/react-native so
// cross-platform teams write identical call-sites.

import PackageDescription

let package = Package(
    name: "Crossdeck",
    platforms: [
        // StoreKit 2 requires iOS 15 / macOS 12. The SDK still works
        // on earlier targets — syncPurchases will reject the rail at
        // runtime — but native developers using StoreKit will pin to
        // these floors anyway. Keep iOS at 13 so non-purchase
        // consumers (analytics-only / errors-only apps) can drop the
        // SDK into older app shells without an OS bump.
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        .library(
            name: "Crossdeck",
            targets: ["Crossdeck"]
        ),
    ],
    dependencies: [
        // Zero runtime dependencies. Every piece of the SDK is
        // implemented against the Foundation / URLSession / OSLog
        // stdlib surface so consumers never inherit a third-party
        // version conflict.
    ],
    targets: [
        .target(
            name: "Crossdeck",
            dependencies: [],
            path: "Sources/Crossdeck",
            swiftSettings: [
                // Strict concurrency catches data races at compile
                // time. The SDK touches mutable state across actors
                // (queue flush, identity hydration, error capture) so
                // we want the compiler to enforce isolation.
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "CrossdeckTests",
            dependencies: ["Crossdeck"],
            path: "Tests/CrossdeckTests"
        ),
    ]
)
