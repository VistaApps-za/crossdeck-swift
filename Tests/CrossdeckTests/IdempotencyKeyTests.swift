// Phase 2.2.c contract tests — Swift deterministic Idempotency-Key.
//
// Pinned cross-SDK oracle: deriveForPurchase("apple", "eyJ.jws.sig",
// nil) MUST equal "a66b1640-efaf-bb4d-1261-6650033bf111" on every
// SDK. The same vector is asserted in:
//   - sdks/web/tests/idempotency-key.test.ts
//   - sdks/node/tests/idempotency-key.test.ts
//   - sdks/react-native/tests/idempotency-key.test.ts
//   - sdks/android/crossdeck/src/test/kotlin/com/crossdeck/IdempotencyKeyTest.kt
// A regression here breaks the wire-protocol parity Stripe-grade
// idempotency depends on — a Web caller retrying via Swift / a
// Swift caller retrying via Web wouldn't collapse on the backend.

import XCTest
@testable import Crossdeck

final class IdempotencyKeyTests: XCTestCase {

    // MARK: - Cross-SDK oracle

    func test_crossSdkOracle_appleJWS() {
        // The canonical vector. Same input on Web/Node/RN/Android
        // must produce this exact UUID. Pin computed via:
        //   node -e "const c=require('crypto');console.log(c.createHash('sha256').update('crossdeck:purchases/sync:apple:eyJ.jws.sig').digest('hex'))"
        // = a66b1640efafbb4d12616650033bf111509f0313643d697a1e6963184b31be51
        // → first 32 hex chars formatted as 8-4-4-4-12:
        let key = IdempotencyKey.deriveForPurchase(
            rail: "apple",
            signedTransactionInfo: "eyJ.jws.sig"
        )
        XCTAssertEqual(key, "a66b1640-efaf-bb4d-1261-6650033bf111")
    }

    // MARK: - Determinism

    func test_sameInputProducesSameKey() {
        let a = IdempotencyKey.deriveForPurchase(
            rail: "apple",
            signedTransactionInfo: "eyJhbGciOiJFUzI1NiJ9.eyJ0eFRpZCI6IjEifQ.sig"
        )
        let b = IdempotencyKey.deriveForPurchase(
            rail: "apple",
            signedTransactionInfo: "eyJhbGciOiJFUzI1NiJ9.eyJ0eFRpZCI6IjEifQ.sig"
        )
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a)
    }

    func test_differentSignedTransactionsProduceDifferentKeys() {
        let a = IdempotencyKey.deriveForPurchase(rail: "apple", signedTransactionInfo: "eyJ.first")
        let b = IdempotencyKey.deriveForPurchase(rail: "apple", signedTransactionInfo: "eyJ.second")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Rail handling

    func test_googleRail_usesPurchaseToken() {
        let key = IdempotencyKey.deriveForPurchase(
            rail: "google",
            purchaseToken: "play-token-abc"
        )
        XCTAssertNotNil(key)
        XCTAssertTrue(
            key?.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                       options: .regularExpression) != nil
        )
    }

    func test_railNamespacing_preventsCrossRailCollisions() {
        // Defence-in-depth: a JWS string that happens to share
        // bytes with a Google token must NOT produce the same key.
        let apple = IdempotencyKey.deriveForPurchase(
            rail: "apple",
            signedTransactionInfo: "shared-bytes"
        )
        let google = IdempotencyKey.deriveForPurchase(
            rail: "google",
            purchaseToken: "shared-bytes"
        )
        XCTAssertNotEqual(apple, google)
    }

    // MARK: - Failure modes

    func test_missingIdentifier_returnsNil() {
        // Bank-grade: never silently mint a random key. Caller must
        // observe the nil and either omit the Idempotency-Key
        // header OR raise a typed error.
        XCTAssertNil(IdempotencyKey.deriveForPurchase(rail: "apple"))
        XCTAssertNil(IdempotencyKey.deriveForPurchase(rail: "google"))
        XCTAssertNil(IdempotencyKey.deriveForPurchase(rail: "stripe"))
    }

    func test_emptyIdentifier_returnsNil() {
        XCTAssertNil(IdempotencyKey.deriveForPurchase(rail: "apple", signedTransactionInfo: ""))
    }

    // MARK: - formatAsUuid

    func test_formatAsUuid_shape() {
        let hex = "0123456789abcdef0123456789abcdef0123456789abcdef"
        XCTAssertEqual(
            IdempotencyKey.formatAsUuid(hex: hex),
            "01234567-89ab-cdef-0123-456789abcdef"
        )
    }

    // MARK: - sha256Hex

    func test_sha256Hex_matchesReferenceVector() {
        // FIPS 180-4 reference: SHA-256("abc")
        // = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        XCTAssertEqual(
            IdempotencyKey.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
