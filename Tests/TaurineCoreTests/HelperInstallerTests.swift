import Foundation
import ServiceManagement
import XCTest
@testable import TaurineCore
@testable import TaurineShared

@MainActor
final class FakeDaemonRegistrar: DaemonRegistering {
    var current: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    var registerCount = 0
    var unregisterCount = 0
    var openedSystemSettings = false
    /// Status assumido após um `register()` bem-sucedido.
    var statusAfterRegister: SMAppService.Status = .enabled

    init(status: SMAppService.Status = .notRegistered) { self.current = status }

    func register() throws {
        self.registerCount += 1
        if let registerError { throw registerError }
        self.current = self.statusAfterRegister
    }

    func unregister() throws {
        self.unregisterCount += 1
        if let unregisterError { throw unregisterError }
        self.current = .notRegistered
    }

    func status() -> SMAppService.Status { self.current }
    func openSystemSettings() { self.openedSystemSettings = true }
}

@MainActor
final class HelperInstallerTests: XCTestCase {
    private func installer(
        registrar: FakeDaemonRegistrar,
        legacyPresent: Bool = false,
        run: @escaping (String, [String]) async throws -> CommandOutput = { _, _ in CommandOutput(status: 0, text: "") }
    ) -> HelperInstaller {
        HelperInstaller(registrar: registrar, fileExists: { _ in legacyPresent }, run: run)
    }

    func testStatusMapsServiceStatus() {
        XCTAssertEqual(HelperInstaller.status(of: .enabled), .installed)
        XCTAssertEqual(HelperInstaller.status(of: .requiresApproval), .requiresApproval)
        XCTAssertEqual(HelperInstaller.status(of: .notRegistered), .missing)
        XCTAssertEqual(HelperInstaller.status(of: .notFound), .missing)
    }

    func testInstallRegistersDaemon() async throws {
        let registrar = FakeDaemonRegistrar()
        let installer = self.installer(registrar: registrar)
        try await installer.install()
        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallSucceedsWhenApprovalIsStillPending() async throws {
        let registrar = FakeDaemonRegistrar()
        registrar.statusAfterRegister = .requiresApproval
        let installer = self.installer(registrar: registrar)
        try await installer.install()
        XCTAssertEqual(installer.status(), .requiresApproval)
    }

    func testInstallFailsWhenDaemonStaysUnregistered() async {
        let registrar = FakeDaemonRegistrar()
        registrar.statusAfterRegister = .notRegistered
        let installer = self.installer(registrar: registrar)
        do {
            try await installer.install()
            XCTFail("expected helperNotInstalled")
        } catch PowerError.helperNotInstalled {
        } catch { XCTFail("unexpected \(error)") }
    }

    func testDeniedAuthorizationMapsToCancelled() async {
        let registrar = FakeDaemonRegistrar()
        registrar.registerError = NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorAuthorizationFailure)
        let installer = self.installer(registrar: registrar)
        do {
            try await installer.install()
            XCTFail("expected cancellation")
        } catch PowerError.cancelled {
        } catch { XCTFail("unexpected \(error)") }
    }

    func testUnregisterToleratesMissingJob() async throws {
        let registrar = FakeDaemonRegistrar(status: .notRegistered)
        registrar.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorJobNotFound)
        try await self.installer(registrar: registrar).remove()
        XCTAssertEqual(registrar.unregisterCount, 1)
    }

    func testRemoveUnregistersDaemon() async throws {
        let registrar = FakeDaemonRegistrar(status: .enabled)
        let installer = self.installer(registrar: registrar)
        try await installer.remove()
        XCTAssertEqual(installer.status(), .missing)
    }

    func testOpenSystemSettingsIsForwarded() {
        let registrar = FakeDaemonRegistrar()
        self.installer(registrar: registrar).openSystemSettings()
        XCTAssertTrue(registrar.openedSystemSettings)
    }

    // MARK: - Migração da instalação legada

    func testLegacyInstallationIsRemovedBeforeRegistering() async throws {
        let registrar = FakeDaemonRegistrar()
        var executables: [String] = []
        var capturedScript: String?
        let installer = self.installer(registrar: registrar, legacyPresent: true) { executable, arguments in
            executables.append(executable)
            capturedScript = arguments.count > 1 ? arguments[1] : nil
            XCTAssertEqual(registrar.registerCount, 0, "o legado precisa sair antes do register()")
            return CommandOutput(status: 0, text: "")
        }
        try await installer.install()
        XCTAssertEqual(executables, ["/usr/bin/osascript"])
        XCTAssertEqual(registrar.registerCount, 1)
        let script = try XCTUnwrap(capturedScript)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("pmset -a disablesleep 0"))
    }

    func testNoLegacyInstallationSkipsPrivilegedScript() async throws {
        let registrar = FakeDaemonRegistrar()
        var ran = false
        let installer = self.installer(registrar: registrar, legacyPresent: false) { _, _ in
            ran = true
            return CommandOutput(status: 0, text: "")
        }
        try await installer.install()
        XCTAssertFalse(ran, "sem legado não deve haver prompt de admin")
    }

    func testCancellingLegacyRemovalAbortsInstall() async {
        let registrar = FakeDaemonRegistrar()
        let installer = self.installer(registrar: registrar, legacyPresent: true) { _, _ in
            CommandOutput(status: 0, text: "TAURINE_AUTH_CANCELLED")
        }
        do {
            try await installer.install()
            XCTFail("expected cancellation")
        } catch PowerError.cancelled {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(registrar.registerCount, 0)
    }

    // MARK: - Script de remoção do legado

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(HelperInstaller.shellQuote("/Users/a b/It's.app"), "'/Users/a b/It'\\''s.app'")
    }

    func testRemovalScriptRemovesEverything() async throws {
        let script = HelperInstaller.removalScript()
        for path in [HelperPaths.legacyBinary, HelperPaths.legacyPlist, HelperPaths.stateDirectory] {
            XCTAssertTrue(script.contains(path), path)
        }
        XCTAssertTrue(script.contains("launchctl bootout system/dev.taurine.helper"))
        let restore = try XCTUnwrap(script.range(of: "/usr/bin/pmset -a disablesleep 0"))
        let bootout = try XCTUnwrap(script.range(of: "launchctl bootout"))
        XCTAssertTrue(restore.upperBound < bootout.lowerBound, "sleep must be restored before the helper is removed")
        try await self.assertShellSyntax(script)
    }

    func testAppleScriptWrapperCompiles() async throws {
        try await self.assertAppleScriptCompiles(HelperInstaller.appleScript(for: HelperInstaller.removalScript()))
    }

    func testAppleScriptEscapesBackslashesAndQuotes() {
        let shellScript = "printf '%s\\n' " + HelperInstaller.shellQuote("/a\\b/c\"d/e'f")
        let result = HelperInstaller.appleScript(for: shellScript)
        let expectedQuoted = "printf '%s\\\\n' '/a\\\\b/c\\\"d/e'\\\\''f'"
        XCTAssertTrue(result.contains(expectedQuoted))
        XCTAssertTrue(result.contains("with administrator privileges"))
        XCTAssertTrue(result.contains("if errorNumber is -128 then"))
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
