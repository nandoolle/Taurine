import Foundation
import XCTest
@testable import TaurineCore

@MainActor
final class FakeSettings: PowerSettings {
    var disabled = false
    var writes: [Bool] = []
    var writeError: Error?
    var onWrite: (() async -> Void)?

    func setSleepDisabled(_ disabled: Bool) async throws {
        self.writes.append(disabled)
        await self.onWrite?()
        if let writeError { throw writeError }
        self.disabled = disabled
    }
}

@MainActor
final class FakeAssertions: WakePreventing {
    var held = false
    var acquireError: Error?
    var releaseError: Error?
    func acquire() throws {
        if let acquireError { throw acquireError }
        self.held = true
    }

    func release() throws {
        if let releaseError { throw releaseError }
        self.held = false
    }
}

@MainActor
final class PowerSessionTests: XCTestCase {
    private func fixture(helperStatus: @escaping () -> HelperInstallStatus = { .installed }) -> (PowerSession, FakeSettings, FakeAssertions) {
        let settings = FakeSettings()
        let assertions = FakeAssertions()
        return (PowerSession(settings: settings, assertions: assertions, helperStatus: helperStatus), settings, assertions)
    }

    func testOnAndOffWriteTheSettingAndReleaseAssertions() async {
        let (session, settings, assertions) = self.fixture()
        XCTAssertEqual(session.state, .inactive)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(settings.disabled)
        XCTAssertTrue(assertions.held)
        let stopped = await session.deactivate()
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertFalse(assertions.held)
    }

    // O app nunca lê o pmset: ativar dispara a escrita mesmo que a máquina já
    // esteja no estado desejado.
    func testActivationWritesWithoutReadingCurrentState() async {
        let (session, settings, _) = self.fixture()
        settings.disabled = true
        await session.activate(duration: nil)
        XCTAssertEqual(settings.writes, [true])
        XCTAssertEqual(session.state, .active)
    }

    func testRevertWritesEvenWhenIdle() async {
        let (session, settings, _) = self.fixture()
        await session.revert()
        XCTAssertEqual(settings.writes, [false])
        XCTAssertEqual(session.state, .inactive)
    }

    func testRevertClearsActiveSessionAndDeadline() async {
        let (session, settings, assertions) = self.fixture()
        await session.activate(duration: 300)
        await session.revert()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.deadline)
        XCTAssertEqual(settings.writes, [true, false])
    }

    // Reverter é best-effort: falhar não pode prender o usuário num app que não
    // fecha nem abrir janela sem que ele tenha clicado.
    func testRevertSwallowsFailures() async {
        let (session, settings, _) = self.fixture()
        settings.writeError = PowerError.commandFailed("x")
        await session.revert()
        XCTAssertNil(session.errorMessage)
    }

    /// Reverter enquanto outra escrita corre deixaria a ordem das chamadas ao
    /// pmset indefinida.
    func testRevertYieldsToAnOperationInFlight() async {
        let (session, settings, _) = self.fixture()
        settings.onWrite = { await session.revert() }
        await session.activate(duration: nil)
        XCTAssertEqual(settings.writes, [true])
        XCTAssertEqual(session.state, .active)
    }

    func testRevertWithoutHelperTouchesNothing() async {
        let (session, settings, _) = self.fixture(helperStatus: { .missing })
        await session.revert()
        XCTAssertTrue(settings.writes.isEmpty)
    }

    func testCancelledActivationLeavesOffWithoutErrorAlert() async {
        let (session, settings, assertions) = self.fixture()
        settings.writeError = PowerError.cancelled
        await session.activate(duration: 300)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.deadline)
        XCTAssertNil(session.errorMessage)
    }

    // Único gatilho da janela de erro: o usuário clicou e o pmset falhou.
    func testFailedActivationReportsAndStaysInactive() async {
        let (session, settings, assertions) = self.fixture()
        settings.writeError = PowerError.commandFailed("pmset exploded")
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.deadline)
    }

    func testFailedDeactivationReportsAndKeepsSessionActive() async {
        let (session, settings, assertions) = self.fixture()
        await session.activate(duration: 300)
        settings.writeError = PowerError.commandFailed("pmset exploded")
        let stopped = await session.deactivate()
        XCTAssertFalse(stopped)
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(assertions.held)
        XCTAssertNotNil(session.errorMessage)
        settings.writeError = nil
        let restored = await session.deactivate()
        XCTAssertTrue(restored)
        XCTAssertFalse(assertions.held)
    }

    func testAssertionFailurePreventsPrivilegedMutation() async {
        let (session, settings, assertions) = self.fixture()
        assertions.acquireError = PowerError.assertionFailed(-1)
        await session.activate(duration: nil)
        XCTAssertTrue(settings.writes.isEmpty)
        XCTAssertEqual(session.state, .inactive)
    }

    func testExpiryNeverOpensAnAlert() async {
        let settings = FakeSettings()
        var now = Date(timeIntervalSince1970: 1000)
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), now: { now }, helperStatus: { .installed })
        await session.activate(duration: 60)
        now = now.addingTimeInterval(59)
        await session.expireIfNeeded()
        XCTAssertEqual(settings.writes, [true])
        settings.writeError = PowerError.commandFailed("x")
        now = now.addingTimeInterval(2)
        await session.expireIfNeeded()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertNil(session.errorMessage, "parada automática não é clique do usuário")
        XCTAssertNil(session.deadline)
    }

    func testTimerCanBeExtendedOrRemovedWithoutAnotherAuthorization() async {
        let (session, settings, _) = self.fixture()
        await session.activate(duration: 60)
        let original = session.deadline!
        await session.activate(duration: 300)
        XCTAssertGreaterThan(session.deadline!, original)
        await session.activate(duration: 0)
        XCTAssertNil(session.deadline)
        XCTAssertEqual(settings.writes, [true])
    }

    func testOverlappingActionsCannotRacePrivilegedMutation() async {
        let (session, settings, _) = self.fixture()
        settings.onWrite = {
            XCTAssertTrue(session.isBusy)
            await session.activate(duration: 300)
            let stopped = await session.deactivate()
            XCTAssertFalse(stopped)
            await session.revert()
        }
        await session.activate(duration: 60)
        XCTAssertEqual(settings.writes, [true])
        XCTAssertEqual(session.state, .active)
        XCTAssertFalse(session.isBusy)
    }

    func testMissingHelperBlocksActivationWithoutTouchingSettings() async {
        let (session, settings, assertions) = self.fixture(helperStatus: { .missing })
        XCTAssertEqual(session.state, .needsHelper)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertEqual(settings.writes, [])
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.errorMessage)
    }

    func testHelperInstalledLaterUnblocksSession() async {
        var status: HelperInstallStatus = .missing
        let (session, _, _) = self.fixture(helperStatus: { status })
        XCTAssertEqual(session.state, .needsHelper)
        status = .installed
        session.helperInstallationChanged()
        XCTAssertEqual(session.state, .inactive)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .active)
    }

    func testOutdatedHelperIsReportedAsNeedsHelper() async {
        let (session, settings, _) = self.fixture()
        settings.writeError = PowerError.helperOutdated
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertTrue(session.helperOutdated)
        XCTAssertNil(session.errorMessage)
    }

    func testActiveSessionLosingHelperReleasesAssertions() async {
        var status: HelperInstallStatus = .installed
        let (session, _, assertions) = self.fixture(helperStatus: { status })
        await session.activate(duration: nil)
        XCTAssertTrue(assertions.held)
        status = .missing
        session.helperInstallationChanged()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertFalse(assertions.held)
    }

    func testNeedsHelperClearsStaleErrorMessage() async {
        var status: HelperInstallStatus = .installed
        let (session, settings, _) = self.fixture(helperStatus: { status })
        settings.writeError = PowerError.commandFailed("x")
        await session.activate(duration: nil)
        XCTAssertNotNil(session.errorMessage)
        status = .missing
        session.helperInstallationChanged()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertNil(session.errorMessage)
    }
}
