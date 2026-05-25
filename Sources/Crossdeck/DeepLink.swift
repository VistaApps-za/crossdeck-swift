// DeepLink — explicit helpers for deep-link / universal-link /
// push-notification interaction tracking.
//
// These are not auto-captured because UIScene's openURL and
// UNUserNotificationCenter's didReceive callbacks live on the
// consumer's AppDelegate / SceneDelegate / NotificationDelegate.
// Apple does not expose a global swizzle target. Instead, the SDK
// ships single-line helpers the consumer forwards from their
// delegate methods. Documented as the canonical Crossdeck pattern
// in the README's "Identity / Attribution" section.
//
// Consumer wiring (SceneDelegate):
//
//   func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
//       for ctx in contexts { Crossdeck.current?.trackDeepLink(url: ctx.url) }
//   }
//
// Consumer wiring (push):
//
//   func userNotificationCenter(_ center: UNUserNotificationCenter,
//                               didReceive response: UNNotificationResponse,
//                               withCompletionHandler completionHandler: @escaping () -> Void) {
//       Crossdeck.current?.trackPushInteraction(
//           userInfo: response.notification.request.content.userInfo,
//           actionIdentifier: response.actionIdentifier
//       )
//       completionHandler()
//   }

import Foundation

extension Crossdeck {
    /// Track a deep link or universal link opening the app.
    ///
    /// Captures: full URL, host, path, query parameters (UTM and
    /// click-id parameters are extracted as top-level properties
    /// for the standard acquisition-attribution dashboard).
    ///
    /// Mirrors Web SDK's session-acquisition capture: utm_*, gclid,
    /// fbclid, msclkid, ttclid, li_fat_id, twclid all surface as
    /// dedicated properties when present.
    public func trackDeepLink(url: URL, source: String? = nil) {
        var props: [String: Any] = [
            "url": url.absoluteString,
        ]
        if let host = url.host, !host.isEmpty { props["host"] = host }
        if !url.path.isEmpty { props["path"] = url.path }
        if let source { props["source"] = source }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            // Extract attribution params per Web SDK convention.
            for item in queryItems {
                let name = item.name.lowercased()
                guard let value = item.value, !value.isEmpty else { continue }
                switch name {
                case "utm_source", "utm_medium", "utm_campaign",
                     "utm_content", "utm_term":
                    props[name] = value
                case "gclid", "fbclid", "msclkid",
                     "ttclid", "li_fat_id", "twclid":
                    props[name] = value
                default:
                    // Non-attribution query params are not promoted —
                    // they pollute the property bag. Consumer can
                    // parse url.query themselves if needed.
                    break
                }
            }
        }

        track("deeplink.opened", properties: props)
    }

    /// Track a push notification interaction (tap, action button).
    ///
    /// `userInfo` is the raw payload from the OS (typically the
    /// `aps` dict plus the consumer's custom keys). `actionIdentifier`
    /// is what the user tapped — the default `UNNotificationDefaultActionIdentifier`
    /// means "tapped the body", or a custom action identifier if the
    /// app registered category actions.
    ///
    /// PII protection: this method does NOT log the alert body or
    /// title — that often contains user-specific content (e.g.
    /// "John sent you a message: Hi!"). It logs only the structural
    /// fields a marketing dashboard needs.
    public func trackPushInteraction(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String? = nil
    ) {
        var props: [String: Any] = [:]
        if let actionIdentifier { props["actionIdentifier"] = actionIdentifier }

        // Surface common marketing-platform IDs that float through
        // the userInfo dict by convention. We do NOT promote unknown
        // keys (would risk leaking PII or business data).
        let surfacedKeys = [
            "campaign_id", "campaignId",
            "message_id", "messageId",
            "notification_id", "notificationId",
            "track_id", "trackId",
            "type", "category",
        ]
        for key in surfacedKeys {
            if let value = userInfo[key], !"\(value)".isEmpty {
                props[key] = "\(value)"
            }
        }
        // The `aps.category` (UNNotificationCategory) often carries
        // the marketing template identifier.
        if let aps = userInfo["aps"] as? [String: Any] {
            if let category = aps["category"] as? String, !category.isEmpty {
                props["aps_category"] = category
            }
        }
        track("push.interacted", properties: props)
    }

    /// Track a push notification *received* (delivered to the app
    /// while in foreground). Wire this from
    /// `userNotificationCenter(_:willPresent:)`.
    ///
    /// Same PII guarantees as `trackPushInteraction`.
    public func trackPushReceived(userInfo: [AnyHashable: Any]) {
        var props: [String: Any] = [:]
        let surfacedKeys = [
            "campaign_id", "campaignId",
            "message_id", "messageId",
            "notification_id", "notificationId",
            "track_id", "trackId",
            "type", "category",
        ]
        for key in surfacedKeys {
            if let value = userInfo[key], !"\(value)".isEmpty {
                props[key] = "\(value)"
            }
        }
        if let aps = userInfo["aps"] as? [String: Any] {
            if let category = aps["category"] as? String, !category.isEmpty {
                props["aps_category"] = category
            }
        }
        track("push.received", properties: props)
    }
}
