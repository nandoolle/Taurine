import XCTest
@testable import TaurineHelper
@testable import TaurineShared

final class BootstrapTests: XCTestCase {
    func testUninstallDecisionRequiresAllThreeConditions() {
        XCTAssertTrue(Bootstrap.shouldUninstall(appPathExists: false, applicationsCopyExists: false, onRootVolume: true))
        XCTAssertFalse(Bootstrap.shouldUninstall(appPathExists: true, applicationsCopyExists: false, onRootVolume: true))
        XCTAssertFalse(Bootstrap.shouldUninstall(appPathExists: false, applicationsCopyExists: true, onRootVolume: true))
        XCTAssertFalse(Bootstrap.shouldUninstall(appPathExists: false, applicationsCopyExists: false, onRootVolume: false))
    }

    func testRootVolumeUsesNearestExistingAncestor() {
        let existing: Set<String> = ["/", "/Volumes", "/Volumes/External", "/Users", "/Users/me"]
        let ids: [String: UInt64] = ["/": 1, "/Volumes": 1, "/Volumes/External": 2, "/Users": 1, "/Users/me": 1]
        let exists: (String) -> Bool = { existing.contains($0) }
        let fsid: (String) -> UInt64? = { ids[$0] }
        XCTAssertTrue(RootVolume.isOnRootVolume("/Users/me/Apps/Taurine.app", exists: exists, fileSystemID: fsid))
        XCTAssertFalse(RootVolume.isOnRootVolume("/Volumes/External/Taurine.app", exists: exists, fileSystemID: fsid))
        XCTAssertTrue(RootVolume.isOnRootVolume("/Nowhere/Taurine.app", exists: exists, fileSystemID: fsid))
    }

    func testRunAlwaysRevertsSleepAndKeepsServingWhenAppExists() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let removed = Removed()
        let env = BootstrapEnvironment(
            fileExists: { $0 == "/Users/me/Taurine.app" },
            isOnRootVolume: { _ in true },
            readAppPath: { "/Users/me/Taurine.app" },
            removeItem: { path in await removed.add(path) },
            bootout: { await removed.add("bootout") }
        )
        let outcome = await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }), environment: env)
        XCTAssertEqual(outcome, .serving)
        let calls = await recorder.calls
        XCTAssertEqual(calls[1], ["/usr/bin/pmset", "-a", "disablesleep", "0"])
        let paths = await removed.paths
        XCTAssertTrue(paths.isEmpty)
    }

    func testRunRevertsWhenSleepStateIsUnreadable() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 1, text: "pmset: read denied"),
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 0\n"),
        ])
        let env = BootstrapEnvironment(
            fileExists: { $0 == "/Users/me/Taurine.app" },
            isOnRootVolume: { _ in true },
            readAppPath: { "/Users/me/Taurine.app" },
            removeItem: { _ in XCTFail("must not remove") },
            bootout: { XCTFail("must not bootout") }
        )
        let outcome = await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }), environment: env)
        XCTAssertEqual(outcome, .serving)
        let calls = await recorder.calls
        XCTAssertEqual(calls[1], ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testRunUninstallsWhenAppIsGone() async {
        let recorder = CommandRecorder(outputs: [CommandOutput(status: 0, text: " SleepDisabled 0\n")])
        let removed = Removed()
        let env = BootstrapEnvironment(
            fileExists: { _ in false },
            isOnRootVolume: { _ in true },
            readAppPath: { "/Users/me/Taurine.app" },
            removeItem: { path in await removed.add(path) },
            bootout: { await removed.add("bootout") }
        )
        let outcome = await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }), environment: env)
        XCTAssertEqual(outcome, .uninstalled)
        let paths = await removed.paths
        XCTAssertEqual(paths, [HelperPaths.installedBinary, HelperPaths.installedPlist, HelperPaths.stateDirectory, "bootout"])
    }

    func testRunKeepsServingWithoutRecordedPath() async {
        let recorder = CommandRecorder(outputs: [CommandOutput(status: 0, text: " SleepDisabled 0\n")])
        let env = BootstrapEnvironment(
            fileExists: { _ in false }, isOnRootVolume: { _ in true }, readAppPath: { nil },
            removeItem: { _ in XCTFail("must not remove") }, bootout: { XCTFail("must not bootout") }
        )
        let outcome = await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }), environment: env)
        XCTAssertEqual(outcome, .serving)
    }
}

actor Removed {
    private(set) var paths: [String] = []
    func add(_ path: String) { self.paths.append(path) }
}
