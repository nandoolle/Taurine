import XCTest
@testable import TaurineHelper
@testable import TaurineShared

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
        XCTAssertTrue(began)

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
        XCTAssertTrue(began)

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
}
