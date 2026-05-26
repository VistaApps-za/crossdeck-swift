// Phase 2.1 contract tests — Swift appAccountToken UUID conformance.
//
// Pre-v1.4.0 the auto-track path stuffed the numeric StoreKit
// originalTransactionId into the wire-level appAccountToken field,
// violating the StoreKit contract that appAccountToken is a UUID.
// The fix derives a proper UUID from developerUserId; the numeric
// id rides in its own dedicated wire field.

import XCTest
@testable import Crossdeck

final class AppAccountTokenDerivationTests: XCTestCase {

    // MARK: - Decision tree

    func test_derive_returnsNil_whenDeveloperUserIdIsNil() {
        XCTAssertNil(AppAccountTokenDerivation.derive(developerUserId: nil))
    }

    func test_derive_returnsNil_whenDeveloperUserIdIsEmpty() {
        XCTAssertNil(AppAccountTokenDerivation.derive(developerUserId: ""))
    }

    func test_derive_returnsLowercaseUUIDDirectly_whenIdIsAlreadyUUID() {
        let id = "550E8400-E29B-41D4-A716-446655440000"
        let result = AppAccountTokenDerivation.derive(developerUserId: id)
        XCTAssertEqual(result, "550e8400-e29b-41d4-a716-446655440000")
    }

    func test_derive_acceptsLowercaseUUIDInput() {
        let id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        let result = AppAccountTokenDerivation.derive(developerUserId: id)
        XCTAssertEqual(result, id)
    }

    func test_derive_derivesUUIDv5_whenIdIsNotUUID() {
        let result = AppAccountTokenDerivation.derive(developerUserId: "user_847")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 36, "Canonical UUID hex form is 8-4-4-4-12 = 36 chars")
        XCTAssertTrue(
            result!.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                          options: .regularExpression) != nil,
            "Result must be a UUID v5 (version nibble = 5, variant high bits = 10xx)"
        )
    }

    func test_derive_isDeterministicAcrossCalls() {
        let a = AppAccountTokenDerivation.derive(developerUserId: "user_847")
        let b = AppAccountTokenDerivation.derive(developerUserId: "user_847")
        XCTAssertEqual(a, b, "UUID v5 must be deterministic — Apple uses it for cross-receipt linkage")
    }

    func test_derive_differentInputsProduceDifferentUUIDs() {
        let alice = AppAccountTokenDerivation.derive(developerUserId: "alice")
        let bob = AppAccountTokenDerivation.derive(developerUserId: "bob")
        XCTAssertNotEqual(alice, bob)
    }

    // MARK: - UUID v5 algorithm correctness

    func test_uuidV5_matchesRFCExample() {
        // RFC 4122 Appendix B vector: v5 of "www.example.com" under
        // the DNS namespace.
        let dnsNamespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let result = AppAccountTokenDerivation.uuidV5(
            namespace: dnsNamespace,
            name: "www.example.com"
        )
        XCTAssertEqual(
            result.uuidString.lowercased(),
            "2ed6657d-e927-568b-95e1-2665a8aea6a2"
        )
    }

    func test_uuidV5_versionAndVariantBitsCorrect() {
        let result = AppAccountTokenDerivation.uuidV5(
            namespace: AppAccountTokenDerivation.crossdeckNamespace,
            name: "any-name"
        )
        let bytes = withUnsafeBytes(of: result.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "Byte 6 high nibble must be 5 (version 5)")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "Byte 8 high bits must be 10xx (RFC 4122 variant)")
    }

    // MARK: - Integration with the auto-track wire shape

    func test_numericStoreKitId_doesNotPassThroughAsAppAccountToken() {
        // The pre-v1.4.0 bug: a numeric originalTransactionId was
        // passed verbatim into appAccountToken. The derivation
        // helper MUST refuse to honour a numeric id as a UUID even
        // if the developerUserId happens to be the numeric form
        // (deterministic derivation kicks in instead).
        let numericId = "1000000111222333"
        let result = AppAccountTokenDerivation.derive(developerUserId: numericId)
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, numericId, "Numeric id MUST NOT pass through as appAccountToken")
        XCTAssertEqual(result?.count, 36)
    }
}
