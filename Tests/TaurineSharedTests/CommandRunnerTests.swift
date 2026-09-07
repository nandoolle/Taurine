import XCTest
@testable import TaurineShared

final class CommandRunnerTests: XCTestCase {
    func testDrainsLargeOutputAndReportsFailures() async throws {
        let result = try await CommandRunner.run("/usr/bin/seq", arguments: ["1", "100000"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.text.hasSuffix("100000"))
        let failed = try await CommandRunner.run("/usr/bin/false", arguments: [])
        XCTAssertNotEqual(failed.status, 0)
    }
}
