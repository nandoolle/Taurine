import Foundation
import XCTest
@testable import TaurineCore

@MainActor
final class FakeSettings: PowerSettings {
    var disabled = false
    var writes: [Bool] = []
    var writeError: Error?
    var readError: Error?
    var ignoresWrites = false
    var failsAfterWrite = false
    var onWrite: (() async -> Void)?

    func sleepIsDisabled() async throws -> Bool {
        if let readError { throw readError }
        return self.disabled
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        self.writes.append(disabled)
        await self.onWrite?()
        if let writeError, !self.failsAfterWrite { throw writeError }
        if !self.ignoresWrites { self.disabled = disabled }
        if let writeError { throw writeError }
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
final class FakeJournal: SessionJournaling {
    var pending = false
    var failSave = false
    func setPending(_ pending: Bool) throws {
        if pending, self.failSave { throw PowerError.commandFailed("Disk full") }
        self.pending = pending
    }
}

@MainActor
final class PowerSessionTests: XCTestCase {
    private func fixture(helperStatus: @escaping () -> HelperInstallStatus = { .installed }) -> (PowerSession, FakeSettings, FakeAssertions, FakeJournal) {
        let settings = FakeSettings()
        let assertions = FakeAssertions()
        let journal = FakeJournal()
        return (PowerSession(settings: settings, assertions: assertions, journal: journal, helperStatus: helperStatus), settings, assertions, journal)
    }

    func testOnAndOffVerifySettingAndReleaseAssertions() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        XCTAssertEqual(session.state, .inactive)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(settings.disabled)
        XCTAssertTrue(assertions.held)
        XCTAssertTrue(journal.pending)
        let stopped = await session.deactivate()
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(journal.pending)
    }

    func testCancelledActivationLeavesOffWithoutErrorAlert() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        settings.writeError = PowerError.cancelled
        await session.activate(duration: 300)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(journal.pending)
        XCTAssertNil(session.deadline)
        XCTAssertNil(session.errorMessage)
    }

    func testCancelledDeactivationRequiresRecoveryAndPreventsQuit() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        await session.activate(duration: 300)
        settings.writeError = PowerError.cancelled
        let stopped = await session.deactivate()
        XCTAssertFalse(stopped)
        XCTAssertEqual(session.state, .recovery)
        XCTAssertTrue(settings.disabled)
        XCTAssertTrue(assertions.held)
        XCTAssertTrue(journal.pending)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertNil(session.deadline)
        settings.writeError = nil
        let restored = await session.deactivate()
        XCTAssertTrue(restored)
        XCTAssertFalse(assertions.held)
    }

    func testStartupDetectsPersistedOrExternallyDisabledSleep() async {
        let (session, settings, assertions, _) = self.fixture()
        settings.disabled = true
        await session.refresh()
        XCTAssertEqual(session.state, .recovery)
        XCTAssertTrue(settings.writes.isEmpty)
        XCTAssertFalse(assertions.held)
        await session.activate(duration: nil)
        XCTAssertTrue(settings.writes.isEmpty)
        let restored = await session.deactivate()
        XCTAssertTrue(restored)
        XCTAssertEqual(settings.writes, [false])
    }

    func testUnreadableStateNeverLooksInactive() async {
        let (session, settings, _, _) = self.fixture()
        settings.readError = PowerError.unreadableState
        await session.refresh()
        XCTAssertEqual(session.state, .recovery)
        let stopped = await session.deactivate()
        XCTAssertFalse(stopped)
        XCTAssertNotNil(session.errorMessage)
    }

    func testSuccessfulCommandWithoutSettingChangeIsNotActivation() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        settings.ignoresWrites = true
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(journal.pending)
    }

    func testSuccessfulCommandWithoutDisablingDoesNotClaimOff() async {
        let (session, settings, assertions, _) = self.fixture()
        await session.refresh()
        await session.activate(duration: nil)
        settings.ignoresWrites = true
        let stopped = await session.deactivate()
        XCTAssertFalse(stopped)
        XCTAssertEqual(session.state, .recovery)
        XCTAssertTrue(assertions.held)
    }

    func testFailureAfterSettingChangedRemainsRecoverable() async {
        let (session, settings, _, journal) = self.fixture()
        await session.refresh()
        settings.writeError = PowerError.commandFailed("Lost response")
        settings.failsAfterWrite = true
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .recovery)
        XCTAssertTrue(journal.pending)
        let restored = await session.deactivate()
        XCTAssertTrue(restored)
        XCTAssertEqual(session.state, .inactive)
    }

    func testJournalFailurePreventsPrivilegedMutation() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        journal.failSave = true
        await session.activate(duration: nil)
        XCTAssertTrue(settings.writes.isEmpty)
        XCTAssertFalse(assertions.held)
        XCTAssertEqual(session.state, .inactive)
    }

    func testAssertionFailurePreventsPrivilegedMutation() async {
        let (session, settings, assertions, _) = self.fixture()
        await session.refresh()
        assertions.acquireError = PowerError.assertionFailed(-1)
        await session.activate(duration: nil)
        XCTAssertTrue(settings.writes.isEmpty)
        XCTAssertEqual(session.state, .inactive)
    }

    func testReleaseFailureDoesNotClaimCompletedSession() async {
        let (session, _, assertions, _) = self.fixture()
        await session.refresh()
        await session.activate(duration: nil)
        assertions.releaseError = PowerError.assertionFailed(-1)
        let stopped = await session.deactivate()
        XCTAssertFalse(stopped)
        XCTAssertEqual(session.state, .recovery)
        assertions.releaseError = nil
        let restored = await session.deactivate()
        XCTAssertTrue(restored)
    }

    func testTimerPromptsOnceAndOnlyAfterDeadline() async {
        let settings = FakeSettings()
        var now = Date(timeIntervalSince1970: 1000)
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), now: { now }, helperStatus: { .installed })
        await session.refresh()
        await session.activate(duration: 60)
        now = now.addingTimeInterval(59)
        await session.expireIfNeeded()
        XCTAssertEqual(settings.writes, [true])
        settings.writeError = PowerError.cancelled
        now = now.addingTimeInterval(2)
        await session.expireIfNeeded()
        await session.expireIfNeeded()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .recovery)
        XCTAssertNil(session.deadline)
    }

    func testTimerCanBeExtendedOrRemovedWithoutAnotherAuthorization() async {
        let (session, settings, _, _) = self.fixture()
        await session.refresh()
        await session.activate(duration: 60)
        let original = session.deadline!
        await session.activate(duration: 300)
        XCTAssertGreaterThan(session.deadline!, original)
        await session.activate(duration: 0)
        XCTAssertNil(session.deadline)
        XCTAssertEqual(settings.writes, [true])
    }

    func testOverlappingActionsCannotRacePrivilegedMutation() async {
        let (session, settings, _, _) = self.fixture()
        await session.refresh()
        settings.onWrite = {
            XCTAssertTrue(session.isBusy)
            await session.activate(duration: 300)
            let stopped = await session.deactivate()
            XCTAssertFalse(stopped)
            await session.refresh()
        }
        await session.activate(duration: 60)
        XCTAssertEqual(settings.writes, [true])
        XCTAssertEqual(session.state, .active)
        XCTAssertFalse(session.isBusy)
    }

    func testExternalRestorationAlsoReleasesLocalAssertions() async {
        let (session, settings, assertions, journal) = self.fixture()
        await session.refresh()
        await session.activate(duration: 60)
        settings.disabled = false
        await session.refresh()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(journal.pending)
        XCTAssertNil(session.deadline)
    }

    func testMissingHelperBlocksActivationWithoutTouchingSettings() async {
        let (session, settings, assertions, _) = self.fixture(helperStatus: { .missing })
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertEqual(settings.writes, [])
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.errorMessage)
    }

    func testHelperInstalledLaterUnblocksSession() async {
        var status: HelperInstallStatus = .missing
        let (session, _, _, _) = self.fixture(helperStatus: { status })
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        status = .installed
        await session.helperInstallationChanged()
        XCTAssertEqual(session.state, .inactive)
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .active)
    }

    func testOutdatedHelperIsReportedAsNeedsHelper() async {
        let (session, settings, _, _) = self.fixture()
        settings.readError = PowerError.helperOutdated
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertTrue(session.helperOutdated)
        XCTAssertNil(session.errorMessage)
    }

    func testActiveSessionLosingHelperReleasesAssertions() async {
        var status: HelperInstallStatus = .installed
        let (session, _, assertions, journal) = self.fixture(helperStatus: { status })
        await session.refresh()
        await session.activate(duration: nil)
        XCTAssertTrue(assertions.held)
        status = .missing
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertFalse(assertions.held)
        XCTAssertTrue(journal.pending, "journal stays pending: pmset may still be 1 and nobody can verify")
    }

    func testHelperOutdatedFlagClearsOnSubsequentGenericFailure() async {
        let (session, settings, _, _) = self.fixture()
        settings.readError = PowerError.helperOutdated
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertTrue(session.helperOutdated)
        settings.readError = PowerError.commandFailed("x")
        await session.refresh()
        XCTAssertEqual(session.state, .recovery)
        XCTAssertFalse(session.helperOutdated)
    }

    func testNeedsHelperClearsStaleErrorMessage() async {
        var status: HelperInstallStatus = .installed
        let (session, settings, _, _) = self.fixture(helperStatus: { status })
        settings.readError = PowerError.commandFailed("x")
        await session.refresh()
        XCTAssertEqual(session.state, .recovery)
        XCTAssertNotNil(session.errorMessage)
        settings.readError = nil
        status = .missing
        await session.refresh()
        XCTAssertEqual(session.state, .needsHelper)
        XCTAssertNil(session.errorMessage)
    }

    func testJournalPersistsAndClearsRecoveryMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SessionJournal(directory: directory)
        try journal.setPending(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-session").path))
        try journal.setPending(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-session").path))
        try journal.setPending(false)
    }
}
