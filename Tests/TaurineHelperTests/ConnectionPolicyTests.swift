import Security
import XCTest
@testable import TaurineHelper
@testable import TaurineShared

final class ConnectionPolicyTests: XCTestCase {
    func testAcceptsConsoleUserRunningTaurine() {
        XCTAssertTrue(ConnectionPolicy.accepts(peerUID: 501, consoleUID: 501, bundleIdentifier: HelperPaths.appBundleIdentifier))
    }

    func testRejectsOtherUsersRootAndOtherApps() {
        XCTAssertFalse(ConnectionPolicy.accepts(peerUID: 502, consoleUID: 501, bundleIdentifier: HelperPaths.appBundleIdentifier))
        XCTAssertFalse(ConnectionPolicy.accepts(peerUID: 0, consoleUID: 501, bundleIdentifier: HelperPaths.appBundleIdentifier))
        XCTAssertFalse(ConnectionPolicy.accepts(peerUID: 501, consoleUID: nil, bundleIdentifier: HelperPaths.appBundleIdentifier))
        XCTAssertFalse(ConnectionPolicy.accepts(peerUID: 501, consoleUID: 501, bundleIdentifier: "com.example.other"))
        XCTAssertFalse(ConnectionPolicy.accepts(peerUID: 501, consoleUID: 501, bundleIdentifier: nil))
    }

    func testBundleIdentifierIsReadFromEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.taurine.app", "CFBundleExecutable": "Fake"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Fake").path
        XCTAssertEqual(ConnectionPolicy.bundleIdentifier(ofExecutableAt: executable), "dev.taurine.app")
        XCTAssertNil(ConnectionPolicy.bundleIdentifier(ofExecutableAt: "/usr/bin/true"))
    }

    func testBundleIdentifierTerminatesOnEmptyAndRelativePaths() {
        XCTAssertNil(ConnectionPolicy.bundleIdentifier(ofExecutableAt: ""))
        XCTAssertNil(ConnectionPolicy.bundleIdentifier(ofExecutableAt: "Fake/Contents/MacOS/Fake"))
        XCTAssertNil(ConnectionPolicy.bundleIdentifier(ofExecutableAt: "relative"))
    }

    // O identificador sozinho é falsificável por qualquer bundle não assinado:
    // é a âncora Apple somada ao time que torna o requisito inforjável.
    func testCodeSigningRequirementPinsIdentifierAnchorAndTeam() {
        let requirement = HelperPaths.clientCodeSigningRequirement
        XCTAssertTrue(requirement.contains(#"identifier "dev.taurine.app""#))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "6Y9HYL9GKV""#))
    }

    func testCodeSigningRequirementIsAcceptedByTheSecurityFramework() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(HelperPaths.clientCodeSigningRequirement as CFString, [], &requirement),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
    }
}
