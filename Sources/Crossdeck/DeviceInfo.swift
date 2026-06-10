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
// Device model identifier (e.g. iPhone15,2) IS now collected, carried
// in the standardized `context.deviceModel` field (Event Envelope v1
// §4) — a short machine identifier string from `utsname`, NOT a
// marketing name and NOT a per-install fingerprint. This is the
// hardware-class signal the cross-SDK context schema requires from
// Apple platforms. (Pre-v1.6.0 Swift omitted it; closed in the v1
// envelope build.)
//
// What we deliberately DO NOT collect:
//
//   * IDFA / IDFV. We are not an ad attribution SDK — the consumer
//     can attach these themselves via super-properties if their app
//     has the ATT permission and they want them.
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
    /// Hardware model identifier (e.g. `iPhone15,2`, `arm64` on a
    /// simulator). Event Envelope v1 §4 `context.deviceModel`. Empty
    /// string when undetectable — the field is omitted from the wire
    /// in that case (see `Crossdeck.track`).
    public let deviceModel: String

    public init(
        platform: String,
        osVersion: String,
        locale: String,
        timezone: String,
        appBundleId: String?,
        appVersion: String?,
        sdkName: String,
        sdkVersion: String,
        deviceModel: String = ""
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.locale = locale
        self.timezone = timezone
        self.appBundleId = appBundleId
        self.appVersion = appVersion
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.deviceModel = deviceModel
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
            sdkVersion: SDK.version,
            deviceModel: detectDeviceModel()
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
        if !deviceModel.isEmpty { p["device_model"] = deviceModel }
        return p
    }

    /// Event Envelope v1 §4 `context` object — the standardized
    /// device/platform facts promoted OUT of `properties` into one
    /// named, top-level wire object. SINGLE SOURCE: both `track()` and
    /// the `$error` capture path read through this so the two can never
    /// drift on field names or coverage (the exact Phase-0 bug, one
    /// level down). Field names are the spec's camelCase (NOT
    /// `asPayload`'s snake_case super-property form): `os`, `osVersion`,
    /// `appVersion`, `sdkName`, `sdkVersion`, `locale`, `timezone`, plus
    /// Apple's `deviceModel`. Optional facts are omitted (never sent as
    /// empty/null) — spec §7 lets the server ignore absent keys.
    public var eventContext: [String: String] {
        var c: [String: String] = [
            "os": platform,
            "osVersion": osVersion,
            "sdkName": sdkName,
            "sdkVersion": sdkVersion,
            "locale": locale,
            "timezone": timezone,
        ]
        if let appVersion { c["appVersion"] = appVersion }
        if !deviceModel.isEmpty { c["deviceModel"] = deviceModel }
        return c
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

/// Hardware model identifier for `context.deviceModel` (Envelope v1
/// §4). Reads `utsname.machine`, the canonical short machine string
/// (`iPhone15,2`, `iPad14,1`, `Mac15,3`, etc.) every Apple platform
/// exposes without UIKit. On the Simulator `utsname.machine` is the
/// host CPU arch (`arm64`/`x86_64`), so we prefer the
/// `SIMULATOR_MODEL_IDENTIFIER` env var which carries the simulated
/// device's identifier. Returns `""` if neither resolves.
private func detectDeviceModel() -> String {
    if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
       !simModel.isEmpty {
        return simModel
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    let model = withUnsafePointer(to: &systemInfo.machine) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
            String(validatingUTF8: cString) ?? ""
        }
    }
    return model
}
