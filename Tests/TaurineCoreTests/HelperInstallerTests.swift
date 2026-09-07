import Foundation
import XCTest
@testable import TaurineCore
@testable import TaurineShared

@MainActor
final class HelperInstallerTests: XCTestCase {
    func testStatusRequiresBothInstalledFiles() {
        let both = HelperInstaller(fileExists: { _ in true }, run: { _, _ in CommandOutput(status: 0, text: "") })
        XCTAssertEqual(both.status(), .installed)
        let onlyPlist = HelperInstaller(fileExists: { $0 == HelperPaths.installedPlist }, run: { _, _ in CommandOutput(status: 0, text: "") })
        XCTAssertEqual(onlyPlist.status(), .missing)
        let none = HelperInstaller(fileExists: { _ in false }, run: { _, _ in CommandOutput(status: 0, text: "") })
        XCTAssertEqual(none.status(), .missing)
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(HelperInstaller.shellQuote("/Users/a b/It's.app"), "'/Users/a b/It'\\''s.app'")
    }

    func testInstallationScriptHasStepsInOrderAndValidSyntax() async throws {
        let script = HelperInstaller.installationScript(bundlePath: "/Users/a b/Taurine.app", uid: 501)
        let order = [
            "launchctl bootout system/dev.taurine.helper",
            "/usr/bin/install -o root -g wheel -m 0755",
            "/usr/bin/install -o root -g wheel -m 0644",
            "/usr/bin/install -d -o root -g wheel -m 0700 /var/db/taurine",
            "/var/db/taurine/app-path",
            "/var/db/taurine/helper-version",
            "/bin/rm -f /private/etc/sudoers.d/taurine-501",
            "launchctl bootstrap system /Library/LaunchDaemons/dev.taurine.helper.plist",
        ]
        var cursor = script.startIndex
        for fragment in order {
            guard let range = script.range(of: fragment, range: cursor..<script.endIndex) else { return XCTFail("missing or out of order: \(fragment)") }
            cursor = range.upperBound
        }
        XCTAssertTrue(script.contains("'/Users/a b/Taurine.app/Contents/Library/LaunchDaemons/dev.taurine.helper'"))
        XCTAssertTrue(script.contains("printf '%s\\n' '\(HelperVersion.current)'"))
        try await self.assertShellSyntax(script)
        try await self.assertShellSyntax(HelperInstaller.removalScript())
    }

    func testRemovalScriptRemovesEverything() {
        let script = HelperInstaller.removalScript()
        for path in [HelperPaths.installedBinary, HelperPaths.installedPlist, HelperPaths.stateDirectory] {
            XCTAssertTrue(script.contains(path), path)
        }
        XCTAssertTrue(script.contains("launchctl bootout system/dev.taurine.helper"))
    }

    func testInstallRunsOsascriptAndMapsCancellation() async {
        var received: [String] = []
        let installer = HelperInstaller(fileExists: { _ in true }, run: { executable, arguments in
            received.append(executable)
            XCTAssertEqual(arguments.first, "-e")
            return CommandOutput(status: 0, text: "TAURINE_AUTH_CANCELLED")
        })
        do {
            try await installer.install(bundlePath: "/Applications/Taurine.app")
            XCTFail("expected cancellation")
        } catch PowerError.cancelled {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(received, ["/usr/bin/osascript"])
    }

    func testInstallFailsIfFilesStillMissing() async {
        let installer = HelperInstaller(fileExists: { _ in false }, run: { _, _ in CommandOutput(status: 0, text: "") })
        do {
            try await installer.install(bundlePath: "/Applications/Taurine.app")
            XCTFail("expected helperNotInstalled")
        } catch PowerError.helperNotInstalled {
        } catch { XCTFail("unexpected \(error)") }
    }

    private func assertShellSyntax(_ script: String) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: path) }
        try script.write(to: path, atomically: true, encoding: .utf8)
        let result = try await CommandRunner.run("/bin/sh", arguments: ["-n", path.path])
        XCTAssertEqual(result.status, 0, result.text)
    }
}
