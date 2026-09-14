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

    /// Update troca o bundle por um inode novo no mesmo caminho. O watcher
    /// precisa se re-armar, senão fica cego pelo resto do boot.
    func testRearmsWatcherWhenBundleReappears() async {
        let recorder = CommandRecorder(outputs: [])
        let ticks = TickCounter()
        let samples = TickCounter()
        let rearms = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in samples.bumpSync() > 1 },
            wait: { if await ticks.bump() > 1 { throw CancellationError() } },
            confirm: {},
            rearm: { _ in _ = rearms.bumpSync() }
        )
        XCTAssertEqual(rearms.bumpSync() - 1, 1, "bundle de volta deve re-armar o watcher")
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "update em andamento não deve reverter o bloqueio")
    }

    func testDoesNotRearmWhileBundleIsStable() async {
        let recorder = CommandRecorder(outputs: [])
        let ticks = TickCounter()
        let rearms = TickCounter()
        await BundleWatchdog.run(
            sleep: SleepControl(run: { try await recorder.run($0, $1) }),
            tracker: await self.ownedTracker(),
            bundlePath: "/Applications/Taurine.app",
            exists: { _ in true },
            wait: { if await ticks.bump() > 3 { throw CancellationError() } },
            rearm: { _ in XCTFail("bundle presente não deve re-armar") }
        )
        _ = rearms
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
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

/// Exercita o caminho de produção: sem injeção de espera, o watchdog monta o
/// observador de verdade. É a única defesa entre apagar o app e um Mac que nunca
/// mais dorme, e nenhum teste com fakes cobre essa composição.
final class BundleWatchdogIntegrationTests: XCTestCase {
    func testRevertsWhenTheRealBundleIsRemoved() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).app").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let tracker = SessionTracker()
        _ = await tracker.begin(SessionToken())
        let watching = Task {
            await BundleWatchdog.run(
                sleep: SleepControl(run: { try await recorder.run($0, $1) }),
                tracker: tracker,
                bundlePath: path,
                confirm: {}
            )
        }
        // Dar tempo de o observador subir antes de remover o bundle.
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(atPath: path)
        var calls: [[String]] = []
        for _ in 0 ..< 50 {
            calls = await recorder.calls
            if calls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        watching.cancel()
        XCTAssertEqual(calls.dropFirst().first, ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }
}

final class BundleWatcherTests: XCTestCase {
    private func temporaryBundle() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).app").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testReportsRemovalOfWatchedBundle() async throws {
        let path = try self.temporaryBundle()
        let watcher = BundleWatcher(path: path)
        await watcher.start()
        let watching = await watcher.isWatching
        XCTAssertTrue(watching)
        try FileManager.default.removeItem(atPath: path)
        try await watcher.nextEvent()
        await watcher.cancel()
    }

    func testReportsRenameOfWatchedBundle() async throws {
        let path = try self.temporaryBundle()
        let moved = path + ".moved"
        defer { try? FileManager.default.removeItem(atPath: moved) }
        let watcher = BundleWatcher(path: path)
        await watcher.start()
        try FileManager.default.moveItem(atPath: path, toPath: moved)
        try await watcher.nextEvent()
        await watcher.cancel()
    }

    /// Cancelar não é evento: acordar por desligamento não pode parecer remoção.
    func testCancelEndsTheWaitByThrowing() async throws {
        let path = try self.temporaryBundle()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let watcher = BundleWatcher(path: path)
        await watcher.start()
        Task { await watcher.cancel() }
        do {
            try await watcher.nextEvent()
            XCTFail("cancelamento deve encerrar a espera com erro")
        } catch is CancellationError {}
    }

    /// Sem descritor o kernel não avisa nada: a espera precisa sobreviver, senão
    /// o watchdog roda em falso.
    func testUnwatchableBundleFallsBackToWaiting() async {
        let watcher = BundleWatcher(path: "/nonexistent/Taurine.app")
        await watcher.start()
        let watching = await watcher.isWatching
        XCTAssertFalse(watching)
        let task = Task { try await watcher.nextEvent() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(task.isCancelled)
        task.cancel()
        await watcher.cancel()
    }

    func testRearmObservesTheReplacementInode() async throws {
        let path = try self.temporaryBundle()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let watcher = BundleWatcher(path: path)
        await watcher.start()
        // Update: o bundle antigo sai e outro ocupa o mesmo caminho.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        await watcher.rearm(path: path)
        let watching = await watcher.isWatching
        XCTAssertTrue(watching)
        try FileManager.default.removeItem(atPath: path)
        try await watcher.nextEvent()
        await watcher.cancel()
    }
}
