import XCTest
@testable import Crossdeck

final class SuperPropertiesTests: XCTestCase {
    func test_register_setsValue() async {
        let storage = MemoryStorage()
        let sp = SuperProperties(storage: storage)
        await sp.register("plan", "pro")
        let snap = await sp.snapshot()
        XCTAssertEqual(snap["plan"], "pro")
    }

    func test_registerOnce_doesNotOverwrite() async {
        let storage = MemoryStorage()
        let sp = SuperProperties(storage: storage)
        await sp.register("plan", "free")
        await sp.registerOnce("plan", "pro")
        let snap = await sp.snapshot()
        XCTAssertEqual(snap["plan"], "free")
    }

    func test_persistsAcrossInstances() async {
        let storage = MemoryStorage()
        let first = SuperProperties(storage: storage)
        await first.register("plan", "pro")
        await first.register("version", "1.2.3")

        let second = SuperProperties(storage: storage)
        let snap = await second.snapshot()
        XCTAssertEqual(snap["plan"], "pro")
        XCTAssertEqual(snap["version"], "1.2.3")
    }

    func test_unregister_removesKey() async {
        let storage = MemoryStorage()
        let sp = SuperProperties(storage: storage)
        await sp.register("plan", "pro")
        await sp.unregister("plan")
        let snap = await sp.snapshot()
        XCTAssertNil(snap["plan"])
    }

    func test_clear_wipesEverything() async {
        let storage = MemoryStorage()
        let sp = SuperProperties(storage: storage)
        await sp.register("a", "1")
        await sp.register("b", "2")
        await sp.clear()
        let snap = await sp.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }
}
