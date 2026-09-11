import XCTest
@testable import TaurineHelper
@testable import TaurineShared

final class BootstrapTests: XCTestCase {
    func testRunRevertsSleepWhenDisabled() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
            CommandOutput(status: 0, text: ""),
        ])
        await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }))
        let calls = await recorder.calls
        XCTAssertEqual(calls[1], ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testRunRevertsWhenSleepStateIsUnreadable() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 1, text: "pmset: read denied"),
            CommandOutput(status: 0, text: ""),
        ])
        await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }))
        let calls = await recorder.calls
        XCTAssertEqual(calls[1], ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testRunDoesNotWriteWhenSleepIsAlreadyEnabled() async {
        let recorder = CommandRecorder(outputs: [CommandOutput(status: 0, text: " SleepDisabled 0\n")])
        await Bootstrap.run(sleep: SleepControl(run: { try await recorder.run($0, $1) }))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, "estado já correto não deve gerar escrita")
    }
}
