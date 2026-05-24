// Device + runtime context collected once per session.
//
// What goes on the wire:
//
//   * Platform string (ios, ipados, macos, tvos, watchos) — derived
//     from compile-time OS, not runtime UIDevice.systemName, so an
//     iOS app running on macOS via Catalyst reports "macos".
//
//   * OS version
//
//   * Locale (e.g. en_US) and timezone (IANA, e.g. America/New_York)
//
//   * App bundle identifier and short version (from Info.plist)
//
//   * SDK identifier (name + version), so server-side debugging can
//     correlate behaviour with a specific SDK release.
//
// What we deliberately DO NOT collect:
//
//   * IDFA / IDFV. We are not an ad attribution SDK — the consumer
//     can attach these themselves via super-properties if their app
//     has the ATT permission and they want them.
//
//   * Device model (e.g. iPhone15,2). Too easily turns into a
//     fingerprint, and not useful for the analytics use cases we
//     target. Operators who need it can opt in via super-properties.
//
// Collected as a struct snapshot at SDK start. We do NOT re-read
// these every event — locale + timezone CAN change at runtime, but
// the overhead of re-reading per event isn't worth the precision
// for the rate of locale changes in the wild.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

public struct DeviceInfo: Sendable, Codable, Equatable {
    public let platform: String
    public let osVersion: String
    public let locale: String
    public let timezone: String
    public let appBundleId: String?
    public let appVersion: String?
    public let sdkName: String
    public let sdkVersion: String

    public init(
        platform: String,
        osVersion: String,
        locale: String,
        timezone: String,
        appBundleId: String?,
        appVersion: String?,
        sdkName: String,
        sdkVersion: String
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.locale = locale
        self.timezone = timezone
        self.appBundleId = appBundleId
        self.appVersion = appVersion
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
    }

    public static func capture() -> DeviceInfo {
        return DeviceInfo(
            platform: detectPlatform(),
            osVersion: detectOSVersion(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            appBundleId: Bundle.main.bundleIdentifier,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sdkName: SDK.name,
            sdkVersion: SDK.version
        )
    }

    /// JSON dict form for inclusion in the event envelope's
    /// `context.device` field.
    public var asPayload: [String: String] {
        var p: [String: String] = [
            "platform": platform,
            "os_version": osVersion,
            "locale": locale,
            "timezone": timezone,
            "sdk_name": sdkName,
            "sdk_version": sdkVersion,
        ]
        if let appBundleId { p["app_bundle_id"] = appBundleId }
        if let appVersion { p["app_version"] = appVersion }
        return p
    }
}

private func detectPlatform() -> String {
    #if os(iOS)
        #if targetEnvironment(macCatalyst)
        return "macos"
        #else
        // Distinguish iPad from iPhone. UI_USER_INTERFACE_IDIOM is
        // not available on watchOS / macOS, hence the canImport
        // guard at file scope.
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "ipados"
        }
        #endif
        return "ios"
        #endif
    #elseif os(macOS)
    return "macos"
    #elseif os(tvOS)
    return "tvos"
    #elseif os(watchOS)
    return "watchos"
    #else
    return "unknown"
    #endif
}

private func detectOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
