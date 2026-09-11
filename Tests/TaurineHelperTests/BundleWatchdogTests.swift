import XCTest
@testable import TaurineHelper
@testable import TaurineShared

final class BundleWatchdogTests: XCTestCase {
    private let executable = "/Applications/Taurine.app/Contents/Library/LaunchDaemons/dev.taurine.helper"

    /// Tracker com sessão ativa: o watchdog só age enquanto alguém é dono.
    private func ownedTracker() async -> SessionTracker {
        let tracker = SessionTracker()
        _ = await tracker.begin(SessionToken())
        return tracker
    }

    func testBundlePathClimbsOutOfLaunchDaemons() {
        XCTAssertEqual(BundleWatchdog.bundlePath(executablePath: self.executable), "/Applications/Taurine.app")
    }

    func testBundlePathRejectsUnexpectedLayout() {
        XCTAssertNil(BundleWatchdog.bundlePath(executablePath: "/usr/local/bin/dev.taurine.helper"))
        XCTAssertNil(BundleWatchdog.bundlePath(executablePath: "/Library/PrivilegedHelperTools/dev.taurine.helper"))
    }

    func testRevertsWhenBundleStaysMissing() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let ticks = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in false },
            wait: { if await ticks.bump() > 1 { throw CancellationError() } },
            confirm: {}
        )
        let calls = await recorder.calls
        XCTAssertEqual(calls[1], ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testBundleReappearingDuringConfirmationIsNotTreatedAsRemoval() async {
        let recorder = CommandRecorder(outputs: [])
        let ticks = TickCounter()
        let samples = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            // Ausente na primeira amostra, presente na confirmação: é um update
            // trocando o bundle, não uma remoção.
            exists: { _ in samples.bumpSync() > 1 },
            wait: { if await ticks.bump() > 1 { throw CancellationError() } },
            confirm: {}
        )
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "update em andamento não deve reverter o bloqueio")
    }

    func testDoesNotActWithoutActiveSession() async {
        let recorder = CommandRecorder(outputs: [])
        let ticks = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: SessionTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in false },
            wait: { if await ticks.bump() > 3 { throw CancellationError() } },
            confirm: { XCTFail("não deve confirmar sem sessão") }
        )
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "sem sessão não há bloqueio para reverter")
    }

    func testDoesNotTouchSleepWhileBundleExists() async {
        let recorder = CommandRecorder(outputs: [])
        let ticks = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in true },
            wait: { if await ticks.bump() > 3 { throw CancellationError() } }
        )
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "bundle presente não deve mexer no pmset")
    }

    func testKeepsWatchingAfterReverting() async {
        // Duas voltas com o bundle ausente: a segunda ainda precisa consultar o
        // pmset, provando que o watchdog não se desarma depois de reverter.
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let ticks = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in false },
            wait: { if await ticks.bump() > 2 { throw CancellationError() } },
            confirm: {}
        )
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2, "o laço deve seguir vigiando após reverter")
    }

    func testMissingBundlePathDoesNothing() async {
        let recorder = CommandRecorder(outputs: [])
        var waited = false
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: nil,
            exists: { _ in false },
            wait: { waited = true }
        )
        XCTAssertFalse(waited, "sem caminho reconhecível o watchdog não deve nem esperar")
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() -> Int { self.bumpSync() }

    func bumpSync() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.count += 1
        return self.count
    }
}
