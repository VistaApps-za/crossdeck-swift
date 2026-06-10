import XCTest
@testable import Crossdeck

/// EventQueue tests use a real HTTPClient pointed at a no-network
/// invalid URL — we never call `flush()` in these tests, only
/// `enqueue`, `persistAll`, and `stats`. The HTTP layer has its
/// own coverage in HttpTests; the queue layer here verifies the
/// buffer / overflow / rehydration contracts in isolation.
final class EventQueueIntegrationTests: XCTestCase {

    private func makeHttp() -> HTTPClient {
        return HTTPClient(
            endpoint: URL(string: "https://example.invalid/v1/events")!,
            publicKey: "cd_pub_test_x"
        )
    }

    private func makeEnvelope() -> EventQueueEnvelope {
        return EventQueueEnvelope(appId: "app_swift_tests", environment: .sandbox)
    }

    func test_enqueue_persistsToStorage() async throws {
        let storage = MemoryStorage()
        let queue = EventQueue(
            http: makeHttp(),
            storage: storage,
            envelope: makeEnvelope(),
            config: makeBatchConfig(batchSize: 100)
        )

        let event = makeWireEvent(name: "e1")
        await queue.enqueue(event)

        await queue.persistAll()

        let blob = storage.getString("queue.buffer.v1")
        XCTAssertNotNil(blob)
    }

    func test_rehydration_restoresBufferedEvents() async {
        let storage = MemoryStorage()
        do {
            let queue = EventQueue(
                http: makeHttp(),
                storage: storage,
                envelope: makeEnvelope(),
                config: makeBatchConfig(batchSize: 100)
            )
            await queue.enqueue(makeWireEvent(name: "e1"))
            await queue.persistAll()
        }
        let queue2 = EventQueue(
            http: makeHttp(),
            storage: storage,
            envelope: makeEnvelope(),
            config: makeBatchConfig(batchSize: 100)
        )
        let stats = await queue2.stats()
        XCTAssertEqual(stats.buffered, 1)
    }

    func test_stats_reportsBufferedCount() async {
        let storage = MemoryStorage()
        let queue = EventQueue(
            http: makeHttp(),
            storage: storage,
            envelope: makeEnvelope(),
            config: makeBatchConfig(batchSize: 100)
        )
        await queue.enqueue(makeWireEvent(name: "e1"))
        await queue.enqueue(makeWireEvent(name: "e2"))
        await queue.enqueue(makeWireEvent(name: "e3"))
        let stats = await queue.stats()
        XCTAssertEqual(stats.buffered, 3)
    }

    func test_overflow_dropsOldestEvents() async {
        let storage = MemoryStorage()
        var cfg = makeBatchConfig(batchSize: 1_000)
        cfg.maxBufferSize = 3
        let queue = EventQueue(
            http: makeHttp(),
            storage: storage,
            envelope: makeEnvelope(),
            config: cfg
        )
        for i in 0..<10 {
            await queue.enqueue(makeWireEvent(name: "e\(i)"))
        }
        let stats = await queue.stats()
        XCTAssertEqual(stats.buffered, 3)
    }

    // MARK: - Event Envelope v1 wire shape (spec §3, §4)

    /// Envelope v1 §3/§4 — a WireEvent carries the per-session `seq`
    /// and the standardized `context` object as first-class fields,
    /// distinct from `properties`. New contract: this assertion is the
    /// wire-shape pin for the envelope-v1 build.
    func test_wireEvent_carriesSeqAndContext() {
        let context: [String: String] = [
            "os": "ios",
            "osVersion": "18.0.0",
            "appVersion": "2.3.1",
            "sdkName": SDK.name,
            "sdkVersion": SDK.version,
            "locale": "en_US",
            "timezone": "America/New_York",
            "deviceModel": "iPhone15,2",
        ]
        let event = WireEvent(
            id: "evt_seqctx",
            name: "page.viewed",
            timestamp: Date(),
            seq: 7,
            properties: ["plan": AnyCodable("pro")],
            context: context,
            anonymousId: "anon_test",
            developerUserId: nil
        )
        XCTAssertEqual(event.seq, 7)
        XCTAssertEqual(event.context["deviceModel"], "iPhone15,2")
        XCTAssertEqual(event.context["os"], "ios")
        // Device facts live in `context`, NOT in `properties`.
        XCTAssertNil(event.properties["os"])
        XCTAssertNotNil(event.properties["plan"])
    }

    /// Envelope v1 §3 — `seq` survives the persist/rehydrate round-trip
    /// (Codable), so a delayed flush across a background/foreground
    /// cycle emits the seq assigned at enqueue time, not a fresh one.
    func test_wireEvent_seqRoundTripsThroughCodable() throws {
        let event = WireEvent(
            id: "evt_rt",
            name: "e1",
            timestamp: Date(),
            seq: 42,
            properties: [:],
            context: ["os": "ios"],
            anonymousId: "anon_test",
            developerUserId: nil
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(WireEvent.self, from: data)
        XCTAssertEqual(decoded.seq, 42)
        XCTAssertEqual(decoded.context["os"], "ios")
    }

    // MARK: - Helpers

    private func makeBatchConfig(batchSize: Int) -> EventQueueConfig {
        var cfg = EventQueueConfig()
        cfg.batchSize = batchSize
        cfg.flushIntervalMs = 10_000
        return cfg
    }

    private func makeWireEvent(name: String) -> WireEvent {
        return WireEvent(
            id: "evt_test_\(UUID().uuidString)",
            name: name,
            timestamp: Date(),
            properties: [:],
            anonymousId: "anon_test",
            developerUserId: nil
        )
    }
}
