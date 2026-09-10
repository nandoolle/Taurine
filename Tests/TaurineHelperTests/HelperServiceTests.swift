import XCTest
@testable import TaurineHelper
@testable import TaurineShared

/// `setSleepDisabled` responde de dentro de um `Task`; conta as chamadas para
/// provar que o reply acontece exatamente uma vez.
private actor ReplyBox {
    private(set) var errors: [NSError?] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var count: Int { self.errors.count }

    func record(_ error: NSError?) {
        self.errors.append(error)
        for waiter in self.waiters { waiter.resume() }
        self.waiters.removeAll()
    }

    func first() async -> NSError? {
        if self.errors.isEmpty {
            await withCheckedContinuation { self.waiters.append($0) }
        }
        return self.errors.first ?? nil
    }
}

final class HelperServiceTests: XCTestCase {
    func testOwnerDeathRevertsDisabledSleep() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let sleep = SleepControl(run: { try await recorder.run($0, $1) })
        let tracker = SessionTracker()
        let owner = SessionToken()
        let began = await tracker.begin(owner)
        XCTAssertEqual(began, .acquired)

        await HelperService.connectionEnded(owner, sleep: sleep, tracker: tracker)

        let calls = await recorder.calls
        XCTAssertEqual(calls.first, ["/usr/bin/pmset", "-g"])
        XCTAssertTrue(calls.contains(["/usr/bin/pmset", "-a", "disablesleep", "0"]))
        let stillOwned = await tracker.isActive(owner)
        XCTAssertFalse(stillOwned)
    }

    func testNonOwnerDeathIssuesNoCommand() async {
        let recorder = CommandRecorder(outputs: [])
        let sleep = SleepControl(run: { try await recorder.run($0, $1) })
        let tracker = SessionTracker()
        let owner = SessionToken(), stranger = SessionToken()
        let began = await tracker.begin(owner)
        XCTAssertEqual(began, .acquired)

        await HelperService.connectionEnded(stranger, sleep: sleep, tracker: tracker)

        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        // A sessão do dono continua intacta.
        let ownerIntact = await tracker.isActive(owner)
        XCTAssertTrue(ownerIntact)
    }

    func testRevertIsSkippedWhenSleepAlreadyEnabled() async {
        let recorder = CommandRecorder(outputs: [CommandOutput(status: 0, text: " SleepDisabled 0\n")])
        let sleep = SleepControl(run: { try await recorder.run($0, $1) })

        await SleepRevert.revertIfDisabled(sleep)

        let calls = await recorder.calls
        XCTAssertEqual(calls, [["/usr/bin/pmset", "-g"]])
    }

    func testRevertTreatsUnreadableStateAsDisabled() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 1, text: "pmset: read denied"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let sleep = SleepControl(run: { try await recorder.run($0, $1) })

        await SleepRevert.revertIfDisabled(sleep)

        let calls = await recorder.calls
        XCTAssertTrue(calls.contains(["/usr/bin/pmset", "-a", "disablesleep", "0"]))
    }

    // Sinal que distingue mismatch de assinatura de encerramento normal: uma
    // conexão reprovada morre antes de qualquer mensagem chegar ao handler.
    func testServedAnyMessageOnlyAfterAMessageArrives() async {
        let recorder = CommandRecorder(outputs: [])
        let handler = ConnectionHandler(
            token: SessionToken(),
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: SessionTracker()
        )
        XCTAssertFalse(handler.servedAnyMessage)

        let box = ReplyBox()
        handler.version { _ in Task { await box.record(nil) } }
        _ = await box.first()

        XCTAssertTrue(handler.servedAnyMessage)
    }

    func testNonOwnerCannotReleaseAnotherSession() async {
        let recorder = CommandRecorder(outputs: [])
        let tracker = SessionTracker()
        let owner = SessionToken(), stranger = SessionToken()
        let began = await tracker.begin(owner)
        XCTAssertEqual(began, .acquired)
        let handler = ConnectionHandler(token: stranger, sleep: SleepControl(run: { try await recorder.run($0, $1) }), tracker: tracker)
        let box = ReplyBox()

        handler.setSleepDisabled(false, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        XCTAssertEqual(error.flatMap(HelperFailure.init)?.code, .busy)
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        let ownerIntact = await tracker.isActive(owner)
        XCTAssertTrue(ownerIntact)
    }

    func testReleaseWithoutOwnerIsAllowed() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let directory = Self.temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let tracker = SessionTracker()
        let handler = ConnectionHandler(
            token: SessionToken(),
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: tracker,
            stateDirectory: directory
        )
        let box = ReplyBox()

        handler.setSleepDisabled(false, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        XCTAssertNil(error)
        let calls = await recorder.calls
        XCTAssertEqual(calls.first, ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testOwnerReleaseIssuesWriteAndFreesSession() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let directory = Self.temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let tracker = SessionTracker()
        let token = SessionToken()
        let began = await tracker.begin(token)
        XCTAssertEqual(began, .acquired)
        let handler = ConnectionHandler(
            token: token,
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: tracker,
            stateDirectory: directory
        )
        let box = ReplyBox()

        handler.setSleepDisabled(false, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        XCTAssertNil(error)
        let calls = await recorder.calls
        XCTAssertEqual(calls.first, ["/usr/bin/pmset", "-a", "disablesleep", "0"])
        let stillOwned = await tracker.isActive(token)
        XCTAssertFalse(stillOwned)
    }

    func testRejectedAppPathIsNotRecorded() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let directory = Self.temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let handler = ConnectionHandler(
            token: SessionToken(),
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: SessionTracker(),
            stateDirectory: directory
        )
        let box = ReplyBox()

        handler.setSleepDisabled(false, appPath: "relative/Taurine.zip") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        XCTAssertNil(error, "o pmset já teve sucesso: caminho inválido não vira erro")
        let file = (directory as NSString).appendingPathComponent("app-path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testAcceptedAppPathIsRecorded() async throws {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let directory = Self.temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let handler = ConnectionHandler(
            token: SessionToken(),
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: SessionTracker(),
            stateDirectory: directory
        )
        let box = ReplyBox()

        handler.setSleepDisabled(false, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        XCTAssertNil(error)
        let file = (directory as NSString).appendingPathComponent("app-path")
        let recorded = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(recorded, "/Applications/Taurine.app\n")
    }

    private static func temporaryStateDirectory() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("taurine-tests-" + UUID().uuidString)
    }

    func testRevertRecoversAfterFailedVerification() async {
        // Cenário do finding: pmset gravou disablesleep 1, a verificação falhou.
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let sleep = SleepControl(run: { try await recorder.run($0, $1) })

        await SleepRevert.revertIfDisabled(sleep)

        let calls = await recorder.calls
        XCTAssertEqual(calls, [
            ["/usr/bin/pmset", "-g"],
            ["/usr/bin/pmset", "-a", "disablesleep", "0"],
            ["/usr/bin/pmset", "-g"],
        ])
    }

    func testFreshAcquisitionRevertsAndReleasesWhenVerifyFails() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),                  // write disablesleep 1
            CommandOutput(status: 0, text: " SleepDisabled 0\n"), // verify disagrees -> throws
            CommandOutput(status: 0, text: " SleepDisabled 1\n"), // revert: read says disabled
            CommandOutput(status: 0, text: ""),                  // revert: write disablesleep 0
            CommandOutput(status: 0, text: " SleepDisabled 0\n"), // revert: verify
        ])
        let tracker = SessionTracker()
        let token = SessionToken()
        let handler = ConnectionHandler(token: token, sleep: SleepControl(run: { try await recorder.run($0, $1) }), tracker: tracker)
        let box = ReplyBox()

        handler.setSleepDisabled(true, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        let calls = await recorder.calls
        XCTAssertTrue(calls.contains(["/usr/bin/pmset", "-a", "disablesleep", "0"]))
        let owned = await tracker.isActive(token)
        XCTAssertFalse(owned)
        XCTAssertEqual(error.flatMap(HelperFailure.init)?.code, .verificationFailed)
        let replies = await box.count
        XCTAssertEqual(replies, 1)
    }

    func testAlreadyOwnerFailureKeepsSessionAndSleepUntouched() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),                  // write disablesleep 1
            CommandOutput(status: 0, text: " SleepDisabled 0\n"), // verify disagrees -> throws
        ])
        let tracker = SessionTracker()
        let token = SessionToken()
        let acquired = await tracker.begin(token)
        XCTAssertEqual(acquired, .acquired)
        let handler = ConnectionHandler(token: token, sleep: SleepControl(run: { try await recorder.run($0, $1) }), tracker: tracker)
        let box = ReplyBox()

        handler.setSleepDisabled(true, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        let error = await box.first()
        let calls = await recorder.calls
        XCTAssertFalse(calls.contains(["/usr/bin/pmset", "-a", "disablesleep", "0"]))
        let stillOwned = await tracker.isActive(token)
        XCTAssertTrue(stillOwned)
        XCTAssertNotNil(error)
        let replies = await box.count
        XCTAssertEqual(replies, 1)
    }

    func testFreshAcquisitionFailureSkipsRevertWhenSleepAlreadyEnabled() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),                  // write disablesleep 1
            CommandOutput(status: 0, text: " SleepDisabled 0\n"), // verify disagrees -> throws
            CommandOutput(status: 0, text: " SleepDisabled 0\n"), // revert: nothing to undo
        ])
        let tracker = SessionTracker()
        let token = SessionToken()
        let handler = ConnectionHandler(token: token, sleep: SleepControl(run: { try await recorder.run($0, $1) }), tracker: tracker)
        let box = ReplyBox()

        handler.setSleepDisabled(true, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        _ = await box.first()
        let calls = await recorder.calls
        XCTAssertFalse(calls.contains(["/usr/bin/pmset", "-a", "disablesleep", "0"]))
        let owned = await tracker.isActive(token)
        XCTAssertFalse(owned)
    }

    func testOwnershipIsHeldUntilRevertCompletes() async {
        // A ordem importa: liberar a sessão antes de reverter abre janela para
        // outra conexão adquiri-la e ter seu bloqueio cancelado pelo revert.
        let tracker = SessionTracker()
        let token = SessionToken(), rival = SessionToken()
        let ownerDuringRevert = OwnershipProbe()
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let sleep = SleepControl(run: { executable, arguments in
            // Durante a escrita do revert, a sessão ainda deve pertencer ao dono.
            if arguments == ["-a", "disablesleep", "0"] {
                let stolen = await tracker.begin(rival)
                await ownerDuringRevert.record(stolen)
            }
            return try await recorder.run(executable, arguments)
        })
        let handler = ConnectionHandler(token: token, sleep: sleep, tracker: tracker)
        let box = ReplyBox()

        handler.setSleepDisabled(true, appPath: "/Applications/Taurine.app") { error in
            Task { await box.record(error) }
        }

        _ = await box.first()
        let stolen = await ownerDuringRevert.value
        XCTAssertEqual(stolen, .busy, "sessão foi liberada antes de o revert terminar")
    }
}

private actor OwnershipProbe {
    private(set) var value: SessionAcquisition?
    func record(_ acquisition: SessionAcquisition) {
        if self.value == nil { self.value = acquisition }
    }
}
