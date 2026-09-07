import XCTest
@testable import TaurineHelper

final class SessionTrackerTests: XCTestCase {
    func testOnlyOneOwnerAtATime() async {
        let tracker = SessionTracker()
        let a = SessionToken(), b = SessionToken()
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

    func testIsActiveTracksOwnershipOnly() async {
        let tracker = SessionTracker()
        let a = SessionToken(), b = SessionToken()
        let idleA = await tracker.isActive(a)
        XCTAssertFalse(idleA)
        _ = await tracker.begin(a)
        let activeA = await tracker.isActive(a)
        let activeB = await tracker.isActive(b)
        XCTAssertTrue(activeA)
        XCTAssertFalse(activeB)
        _ = await tracker.end(a)
        let endedA = await tracker.isActive(a)
        XCTAssertFalse(endedA)
    }

    func testFreshTokensNeverCollide() {
        XCTAssertNotEqual(SessionToken(), SessionToken())
    }
}
