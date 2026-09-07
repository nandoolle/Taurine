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
        var capturedScript: String?
        let installer = HelperInstaller(fileExists: { _ in true }, run: { executable, arguments in
            received.append(executable)
            XCTAssertEqual(arguments.first, "-e")
            capturedScript = arguments.count > 1 ? arguments[1] : nil
            return CommandOutput(status: 0, text: "TAURINE_AUTH_CANCELLED")
        })
        do {
            try await installer.install(bundlePath: "/Applications/Taurine.app")
            XCTFail("expected cancellation")
        } catch PowerError.cancelled {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(received, ["/usr/bin/osascript"])
        let script = try? XCTUnwrap(capturedScript)
        XCTAssertTrue(script?.contains("do shell script") ?? false)
        XCTAssertTrue(script?.contains("with administrator privileges") ?? false)
        XCTAssertTrue(script?.contains("'/Applications/Taurine.app/Contents/Library/LaunchDaemons/dev.taurine.helper'") ?? false)
    }

    func testAppleScriptWrapperCompiles() async throws {
        let bundlePath = "/Users/a b/It's \"odd\"\\path/Taurine.app"
        let installScript = HelperInstaller.appleScript(for: HelperInstaller.installationScript(bundlePath: bundlePath, uid: 501))
        try await self.assertAppleScriptCompiles(installScript)
        let removeScript = HelperInstaller.appleScript(for: HelperInstaller.removalScript())
        try await self.assertAppleScriptCompiles(removeScript)
    }

    func testAppleScriptEscapesBackslashesAndQuotes() {
        let shellScript = "printf '%s\\n' " + HelperInstaller.shellQuote("/a\\b/c\"d/e'f")
        let result = HelperInstaller.appleScript(for: shellScript)
        let expectedQuoted = "printf '%s\\\\n' '/a\\\\b/c\\\"d/e'\\\\''f'"
        XCTAssertTrue(result.contains(expectedQuoted))
        XCTAssertTrue(result.contains("with administrator privileges"))
        XCTAssertTrue(result.contains("if errorNumber is -128 then"))
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

    private func assertAppleScriptCompiles(_ script: String) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".applescript")
        let compiled = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: compiled)
        }
        try script.write(to: source, atomically: true, encoding: .utf8)
        let result = try await CommandRunner.run("/usr/bin/osacompile", arguments: ["-o", compiled.path, source.path])
        XCTAssertEqual(result.status, 0, result.text)
    }
}
