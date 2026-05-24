import XCTest
@testable import Crossdeck

final class BreadcrumbsTests: XCTestCase {
    func test_ring_dropsOldest_atCapacity() async {
        let b = Breadcrumbs(capacity: 3)
        await b.add(Breadcrumb(category: .ui, message: "one"))
        await b.add(Breadcrumb(category: .ui, message: "two"))
        await b.add(Breadcrumb(category: .ui, message: "three"))
        await b.add(Breadcrumb(category: .ui, message: "four"))
        let snap = await b.snapshot()
        XCTAssertEqual(snap.map(\.message), ["two", "three", "four"])
    }

    func test_clear_empties() async {
        let b = Breadcrumbs(capacity: 5)
        await b.add(Breadcrumb(category: .ui, message: "x"))
        await b.clear()
        let snap = await b.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    func test_snapshot_isCopy_notLiveReference() async {
        let b = Breadcrumbs(capacity: 5)
        await b.add(Breadcrumb(category: .ui, message: "first"))
        let snap1 = await b.snapshot()
        await b.add(Breadcrumb(category: .ui, message: "second"))
        XCTAssertEqual(snap1.count, 1)
    }
}
