import XCTest
@testable import TaurineHelper

final class SessionTrackerTests: XCTestCase {
    func testOnlyOneOwnerAtATime() async {
        let tracker = SessionTracker()
        // As conexões devem continuar vivas: ObjectIdentifier de temporários
        // colide, porque o alocador reusa o endereço liberado.
        let objectA = NSObject(), objectB = NSObject()
        let a = ObjectIdentifier(objectA), b = ObjectIdentifier(objectB)
        XCTAssertNotEqual(a, b)
        let first = await tracker.begin(a)
        let second = await tracker.begin(b)
        let again = await tracker.begin(a)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(again)
        let endedByStranger = await tracker.end(b)
        let endedByOwner = await tracker.end(a)
        let ownerAfter = await tracker.end(a)
        XCTAssertFalse(endedByStranger)
        XCTAssertTrue(endedByOwner)
        XCTAssertFalse(ownerAfter)
        let bNow = await tracker.begin(b)
        XCTAssertTrue(bNow)
    }
}
