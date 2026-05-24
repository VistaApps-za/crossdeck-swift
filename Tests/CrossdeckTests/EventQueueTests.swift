import XCTest
@testable import Crossdeck

/// EventQueue tests use a real HTTPClient pointed at a no-network
/// invalid URL — we never call `flush()` in these tests, only
/// `enqueue`, `persistAll`, and `stats`. The HTTP layer has its
/// own coverage in HttpTests; the queue layer here verifies the
/// buffer / overflow / rehydration contracts in isolation.
final class EventQueueIntegrationTests: XCTestCase {
    func test_enqueue_persistsToStorage() async throws {
        let storage = MemoryStorage()
        let queue = EventQueue(
            http: HTTPClient(
                endpoint: URL(string: "https://example.invalid/v1/events")!,
                writeKey: "test"
            ),
            storage: storage,
            config: makeBatchConfig(batchSize: 100)
        )

        let event = makeWireEvent(name: "e1")
        await queue.enqueue(event)

        // Persistence is async — give the actor a beat.
        await queue.persistAll()

        let blob = storage.getString("queue.buffer")
        XCTAssertNotNil(blob)
    }

    func test_rehydration_restoresBufferedEvents() async {
        let storage = MemoryStorage()
        do {
            let queue = EventQueue(
                http: HTTPClient(
                    endpoint: URL(string: "https://example.invalid/v1/events")!,
                    writeKey: "test"
                ),
                storage: storage,
                config: makeBatchConfig(batchSize: 100)
            )
            await queue.enqueue(makeWireEvent(name: "e1"))
            await queue.persistAll()
        }
        // Fresh queue instance off same storage — should rehydrate.
        let queue2 = EventQueue(
            http: HTTPClient(
                endpoint: URL(string: "https://example.invalid/v1/events")!,
                writeKey: "test"
            ),
            storage: storage,
            config: makeBatchConfig(batchSize: 100)
        )
        let stats = await queue2.stats()
        XCTAssertEqual(stats.buffered, 1)
    }

    func test_stats_reportsBufferedCount() async {
        let storage = MemoryStorage()
        let queue = EventQueue(
            http: HTTPClient(
                endpoint: URL(string: "https://example.invalid/v1/events")!,
                writeKey: "test"
            ),
            storage: storage,
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
            http: HTTPClient(
                endpoint: URL(string: "https://example.invalid/v1/events")!,
                writeKey: "test"
            ),
            storage: storage,
            config: cfg
        )
        for i in 0..<10 {
            await queue.enqueue(makeWireEvent(name: "e\(i)"))
        }
        let stats = await queue.stats()
        XCTAssertEqual(stats.buffered, 3)
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
            id: "cdevt_test_\(UUID().uuidString)",
            name: name,
            timestamp: Date(),
            properties: [:],
            anonymousId: "cdanon_test",
            customerId: nil
        )
    }
}
