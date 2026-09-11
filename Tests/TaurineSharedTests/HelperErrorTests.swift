import Foundation
import XCTest
@testable import TaurineShared

final class HelperErrorTests: XCTestCase {
    func testFailureRoundTripsThroughNSError() {
        let failure = HelperFailure(code: .commandFailed, message: "pmset exploded")
        let bridged = failure.nsError
        XCTAssertEqual(bridged.domain, HelperError.domain)
        XCTAssertEqual(bridged.code, HelperError.commandFailed.rawValue)
        let restored = HelperFailure(bridged)
        XCTAssertEqual(restored?.code, .commandFailed)
        XCTAssertEqual(restored?.message, "pmset exploded")
    }

    func testFailureWithoutMessageBridges() {
        let restored = HelperFailure(HelperFailure(code: .busy).nsError)
        XCTAssertEqual(restored?.code, .busy)
        XCTAssertNil(restored?.message)
    }

    func testForeignErrorIsNotAHelperFailure() {
        XCTAssertNil(HelperFailure(NSError(domain: NSCocoaErrorDomain, code: 4097)))
        XCTAssertNil(HelperFailure(NSError(domain: HelperError.domain, code: 999)))
    }

    func testPathsAreAbsoluteAndConsistent() {
        XCTAssertEqual(HelperPaths.label, "dev.taurine.helper")
        XCTAssertEqual(HelperPaths.machService, HelperPaths.label)
        XCTAssertEqual(HelperPaths.daemonPlistName, "dev.taurine.helper.plist")
        XCTAssertEqual(HelperPaths.legacyBinary, "/Library/PrivilegedHelperTools/dev.taurine.helper")
        XCTAssertEqual(HelperPaths.legacyPlist, "/Library/LaunchDaemons/dev.taurine.helper.plist")
        XCTAssertEqual(HelperVersion.current, 2)
    }
}
