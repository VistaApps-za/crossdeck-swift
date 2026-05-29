// Server-endpoint response shapes + Crossdeck client extensions for
// the non-events HTTP surface.
//
// The events queue has its own POST /events path. Everything else
// — heartbeat, identity alias, identity forget, entitlements fetch,
// purchase sync — goes through this layer. Response shapes mirror
// the canonical `sdks/react-native/src/types.ts` exactly so an
// SDK-aware backend change ripples to all four SDKs identically.

import Foundation

// MARK: - Wire shapes

/// Audit rail tags returned on every entitlement source.
public enum AuditRail: String, Sendable, Codable {
    case stripe
    case apple
    case google
    case manual
}

/// Single entitlement returned by `/entitlements` or `/purchases/sync`.
/// Mirrors `PublicEntitlement` in the RN SDK.
public struct PublicEntitlement: Sendable, Codable, Equatable {
    public let key: String
    public let isActive: Bool
    /// Optional `validUntil` epoch ms — when set, `isEntitled(key)`
    /// returns false past this moment even when `isActive` is true.
    public let validUntil: Int64?
    public let source: EntitlementSource
    public let updatedAt: Int64

    public struct EntitlementSource: Sendable, Codable, Equatable {
        public let rail: AuditRail
        public let productId: String
        public let subscriptionId: String
    }

    public init(
        key: String,
        isActive: Bool,
        validUntil: Int64? = nil,
        source: EntitlementSource,
        updatedAt: Int64
    ) {
        self.key = key
        self.isActive = isActive
        self.validUntil = validUntil
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// `POST /identity/alias` response. Returned to `identifyAndWait(...)`
/// so the consumer can stash `crossdeckCustomerId` if they want to
/// (the SDK also persists it automatically).
public struct AliasResult: Sendable, Codable, Equatable {
    public let crossdeckCustomerId: String
    public let mergePending: Bool
    public let env: CrossdeckEnvironment

    public struct LinkedIdentity: Sendable, Codable, Equatable {
        public let type: String   // "developer" | "anonymous"
        public let id: String
    }
    /// Backend always emits `linked: []`, but a future server-side
    /// change shouldn't crash the Swift decoder on a missing field.
    /// Default to empty when absent.
    public let linked: [LinkedIdentity]?
}

/// `GET /entitlements` response.
public struct EntitlementsListResponse: Sendable, Codable, Equatable {
    public let data: [PublicEntitlement]
    public let crossdeckCustomerId: String
    public let env: CrossdeckEnvironment
}

/// `POST /purchases/sync` response. Carries the projected
/// entitlement set so the SDK can warm its cache immediately.
///
/// `idempotentReplay` is set to `true` when the backend short-
/// circuits a same-key-same-body retry from its 24h Idempotency-Key
/// response cache (Stripe-style replay). Surface it on the
/// `purchase.completed` analytics event so dashboards can split
/// "fresh purchase" from "retried purchase" in funnels. The wire
/// key is `idempotent_replay` (snake_case, set by the backend's
/// idempotency-response-cache middleware) — CodingKey bridges to
/// the Swift-idiomatic camelCase property name.
public struct PurchaseResult: Sendable, Codable, Equatable {
    public let crossdeckCustomerId: String
    public let env: CrossdeckEnvironment
    public let entitlements: [PublicEntitlement]
    public let idempotentReplay: Bool?

    enum CodingKeys: String, CodingKey {
        case crossdeckCustomerId
        case env
        case entitlements
        case idempotentReplay = "idempotent_replay"
    }
}

/// `GET /sdk/heartbeat` response. Used to flip the dashboard
/// onboarding checklist to LIVE within ~200ms and to capture
/// server-time for clock-skew detection.
public struct HeartbeatResponse: Sendable, Codable, Equatable {
    public let ok: Bool
    public let projectId: String
    public let appId: String
    public let env: CrossdeckEnvironment
    public let serverTime: Int64
}

// MARK: - Request body shapes

/// `POST /identity/alias` request body. environment + appId are
/// derived server-side from the API key (resolveAppKey) — sending
/// them here would be ignored. Matches the wire shape Web/Node/RN
/// ship to backend/src/api/v1-alias.ts.
struct AliasIdentityRequest: Encodable {
    let userId: String
    let anonymousId: String
    let email: String?
    let traits: [String: String]?
    /// Apple-rail purchase identity, when the install has already
    /// minted one via `Crossdeck.appAccountTokenForCurrentIdentity()`.
    /// Sent on every `identify()` so the server records the
    /// (appAccountToken → developerUserId) binding before any later
    /// ASSN V2 webhook arrives carrying that token. Closes the
    /// Shape 2 trap by making the server-side join authoritative
    /// rather than implicitly assuming `appAccountToken ==
    /// developerUserId`. `nil` when the install has never touched
    /// Apple-rail purchases.
    let appAccountToken: String?
}

/// `POST /identity/forget` request body.
///
/// Field-naming note: the backend reads `customerId` (not
/// `crossdeckCustomerId`) — see `backend/src/api/v1-forget.ts:131`.
/// `environment` + `appId` are derived server-side from the API
/// key, so they're not sent in the body.
struct ForgetIdentityRequest: Encodable {
    let userId: String?
    let anonymousId: String?
    let customerId: String?
}

/// `POST /purchases/sync` request body. Customer linkage is derived
/// from the Apple JWS signature server-side; identity-hint fields
/// would be ignored. Matches the wire shape the backend validator
/// reads (backend/src/api/v1-purchases-validation.ts).
///
/// v1.0.1 only supports rail=apple (Apple StoreKit 2). The backend
/// rejects rail=google explicitly (`google_not_supported`); Google
/// Play wiring ships in v1.1.
struct PurchaseSyncRequest: Encodable {
    let rail: String
    let signedTransactionInfo: String?
    let signedRenewalInfo: String?
    /// RFC 4122 UUID (canonical 8-4-4-4-12 lowercase hex). Derived
    /// from `developerUserId` via [[AppAccountTokenDerivation]] on
    /// the auto-track path; passed by the caller on the manual
    /// `syncPurchases` path. Backend rejects non-UUID values with
    /// 400 as of v1.4.0.
    let appAccountToken: String?
    /// StoreKit's `Transaction.originalID` — numeric string. Lives
    /// on its own wire field as of v1.4.0 so it never collides
    /// with the UUID-shaped `appAccountToken`.
    let originalTransactionId: String?
}
