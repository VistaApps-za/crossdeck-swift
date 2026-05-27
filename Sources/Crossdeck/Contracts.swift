// Public, typed accessor for the bank-grade behavioural contracts
// this SDK ships. The full architecture — schema, distribution,
// audit loop, pillar taxonomy — lives in `contracts/README.md`
// at the monorepo root.
//
// Why a typed surface (vs. raw JSON access): contract IDs and
// pillar names are part of Crossdeck's public commitment to
// customers. Reading them through `CrossdeckContracts` means the
// compiler catches drift the moment a contract is renamed or
// retired. Tools that consume contracts at runtime (dashboards,
// AI assistants, customer integration tests) get the exact same
// shape every SDK ships, with no parsing layer to drift.
//
// --- BINARY STABILITY ---
// `Contract` is treated as an evolving — but back-compat — wire
// shape. Fields may be added in any minor release. Existing
// fields will not be removed or repurposed except in a major
// version bump, even if all known contracts stop using them.
// Customers can rely on `id`, `pillar`, `status`, `appliesTo`,
// `codeRef`, `testRef`, `registeredAt`, `firstRegisteredIn`,
// and `bundledIn` being present on every contract in every
// future minor/patch release of this SDK.

import Foundation

/// Which bank-grade pillar a contract belongs to. The taxonomy is
/// deliberately small — every contract maps to exactly one. New
/// pillars require a Crossdeck major-version bump.
public enum ContractPillar: String, Codable, Sendable, CaseIterable {
    case revenue
    case entitlements
    case analytics
    case webhooks
    case errors
    case lifecycle
    case identity
}

/// Lifecycle stage of a contract.
/// - `enforced`: live in this SDK and exercised by `testRef`.
/// - `proposed`: registered for an upcoming release; `testRef`
///    may point to a not-yet-existing file.
/// - `retired`: kept for history only; filtered out of `.all()`.
public enum ContractStatus: String, Codable, Sendable, CaseIterable {
    case enforced
    case proposed
    case retired
}

/// Which SDKs (and/or `backend`) a contract is binding on.
public enum ContractAppliesTo: String, Codable, Sendable, CaseIterable {
    case web
    case node
    case reactNative = "react-native"
    case swift
    case android
    case backend
}

/// Pointer to the test that exercises a contract clause. The
/// `name` is matched verbatim against the file's text by
/// `scripts/contract-audit.mjs`, so a rename without updating
/// the contract aborts CI.
public struct ContractTestRef: Codable, Hashable, Sendable {
    public let file: String
    public let name: String
}

/// One bank-grade behavioural guarantee — see `contracts/README.md`.
public struct Contract: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pillar: ContractPillar
    public let status: ContractStatus
    public let claim: String
    public let appliesTo: [ContractAppliesTo]
    public let codeRef: [String]
    public let testRef: [ContractTestRef]
    /// ISO-8601 date the contract was first registered.
    public let registeredAt: String
    /// The release note / phase the contract first appeared in. Immutable.
    public let firstRegisteredIn: String
    /// The SDK release this snapshot was bundled with, stamped at build time.
    public let bundledIn: String
}

private struct ContractsBundle: Decodable {
    let bundledIn: String
    let sdkVersion: String
    let contracts: [Contract]
}

/// Input to `Crossdeck.reportContractFailure(_:)`. Mirrors the
/// per-SDK shape exactly — the Crossdeck dashboard joins
/// `crossdeck.contract_failed` events across every SDK on
/// `contract_id`, so the property bag has to agree byte-for-byte.
///
/// SCHEMA-LOCK: this struct's field set is exhaustively named. No
/// free-form `extra: [String: Any]?` — the schema-lock contract at
/// `contracts/diagnostics/contract-failed-payload-schema-lock.json`
/// forbids unbounded fields. Adding a field requires a PR that
/// amends the contract first, then the public struct.
public struct ContractFailureInput: Sendable {
    /// Where the failure was observed.
    public enum RunContext: String, Sendable {
        case ci
        case dogfood
        case customerApp = "customer-app"
    }

    /// Stable contract id (`per-user-cache-isolation` etc.).
    public let contractId: String
    /// Short categorical-ish label — the SDK convention is to keep
    /// this under 128 chars and stable across runs (so dashboards can
    /// group). Never an end-user-supplied string.
    public let failureReason: String
    public let runContext: RunContext
    /// Stable identifier for this verification run.
    public let runId: String
    /// Optional pointer back to the failing test, for triage.
    public let testRef: TestRefSnapshot?
    /// Optional coarse device class, e.g. "iPhone", "iPad", "Mac",
    /// "simulator". A categorical bucket, not a device identifier.
    public let deviceClass: String?

    public struct TestRefSnapshot: Sendable, Hashable {
        public let file: String
        public let name: String
        public init(file: String, name: String) {
            self.file = file
            self.name = name
        }
    }

    public init(
        contractId: String,
        failureReason: String,
        runContext: RunContext,
        runId: String,
        testRef: TestRefSnapshot? = nil,
        deviceClass: String? = nil
    ) {
        self.contractId = contractId
        self.failureReason = failureReason
        self.runContext = runContext
        self.runId = runId
        self.testRef = testRef
        self.deviceClass = deviceClass
    }
}

/// Typed entry point to the bank-grade contracts bundled with this
/// SDK release. Stable, side-effect-free, lazy-loaded once.
///
/// ```swift
/// import Crossdeck
///
/// for contract in CrossdeckContracts.all() {
///     print("[crossdeck] \(contract.id) (\(contract.pillar.rawValue))")
/// }
///
/// guard let isolation = CrossdeckContracts.byId("per-user-cache-isolation"),
///       isolation.status == .enforced else {
///     fatalError("entitlement isolation contract is not enforced")
/// }
/// ```
public enum CrossdeckContracts {
    /// Every contract that applies to this SDK and is currently enforced.
    public static func all() -> [Contract] {
        loaded.contracts.filter { $0.status == .enforced }
    }

    /// Every contract bundled with this SDK release, including
    /// `proposed` and `retired` entries. Use `all()` for the
    /// enforced-only view.
    public static func allIncludingHistorical() -> [Contract] {
        loaded.contracts
    }

    /// Look up a contract by its stable `id`.
    public static func byId(_ id: String) -> Contract? {
        loaded.contracts.first { $0.id == id }
    }

    /// Every enforced contract within a pillar.
    public static func byPillar(_ pillar: ContractPillar) -> [Contract] {
        loaded.contracts.filter { $0.pillar == pillar && $0.status == .enforced }
    }

    /// Filter by lifecycle status.
    public static func withStatus(_ status: ContractStatus) -> [Contract] {
        loaded.contracts.filter { $0.status == status }
    }

    /// Semver of the SDK release these contracts were bundled with.
    public static var sdkVersion: String { loaded.sdkVersion }

    /// Fully-qualified bundle identifier — e.g. `@cross-deck/swift@1.4.1`.
    public static var bundledIn: String { loaded.bundledIn }

    /// Resolve a failing test back to the contract it exercises.
    /// Used by XCTestObservation hooks to find the contract id of
    /// a failed contract test so `reportContractFailure(_:)` can
    /// stamp the right `contract_id` on the emitted event.
    public static func findByTestName(_ name: String) -> Contract? {
        loaded.contracts.first { contract in
            contract.testRef.contains { $0.name == name }
        }
    }

    // MARK: - Lazy load from the bundled Resources/contracts.json

    private static let loaded: ContractsBundle = {
        guard let url = Bundle.module.url(forResource: "contracts", withExtension: "json") else {
            // The resource is .copy-listed in Package.swift, so a missing
            // file means the SDK was assembled wrong — treat as fatal.
            preconditionFailure("Crossdeck: Resources/contracts.json missing from the SDK bundle. Run `node Scripts/emit-contracts.mjs` and rebuild.")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(ContractsBundle.self, from: data)
        } catch {
            preconditionFailure("Crossdeck: failed to decode bundled contracts.json: \(error)")
        }
    }()
}
