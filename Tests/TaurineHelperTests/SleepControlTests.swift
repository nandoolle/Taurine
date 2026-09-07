import XCTest
@testable import TaurineHelper
@testable import TaurineShared

final class SleepControlTests: XCTestCase {
    func testParserAcceptsOnlyExactSleepDisabledLine() throws {
        XCTAssertFalse(try SleepControl.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\nAC Power:\n sleep 0"))
        XCTAssertTrue(try SleepControl.parseSleepDisabled(" SleepDisabled 1\n"))
        XCTAssertThrowsError(try SleepControl.parseSleepDisabled("sleep 0\n")) { XCTAssertEqual(($0 as? HelperFailure)?.code, .unreadableState) }
        XCTAssertThrowsError(try SleepControl.parseSleepDisabled("SleepDisabled 2\n"))
        XCTAssertThrowsError(try SleepControl.parseSleepDisabled("NotSleepDisabled 1\n"))
    }

    func testSetWritesThenVerifies() async throws {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
        ])
        let control = SleepControl(run: { try await recorder.run($0, $1) })
        try await control.setDisabled(true)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [
            ["/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["/usr/bin/pmset", "-g"],
        ])
    }

    func testSetFailsWhenVerificationDisagrees() async {
        let recorder = CommandRecorder(outputs: [
            CommandOutput(status: 0, text: ""),
            CommandOutput(status: 0, text: " SleepDisabled 1\n"),
        ])
        let control = SleepControl(run: { try await recorder.run($0, $1) })
        do {
            try await control.setDisabled(false)
            XCTFail("expected verificationFailed")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, .verificationFailed)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testCommandErrorCarriesOutputText() async {
        let recorder = CommandRecorder(outputs: [CommandOutput(status: 1, text: "pmset: not permitted")])
        let control = SleepControl(run: { try await recorder.run($0, $1) })
        do {
            try await control.setDisabled(true)
            XCTFail("expected commandFailed")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, .commandFailed)
            XCTAssertEqual(failure.message, "pmset: not permitted")
        } catch { XCTFail("unexpected \(error)") }
    }
}

actor CommandRecorder {
    private(set) var calls: [[String]] = []
    private var outputs: [CommandOutput]

    init(outputs: [CommandOutput]) { self.outputs = outputs }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput {
        self.calls.append([executable] + arguments)
        guard !self.outputs.isEmpty else { return CommandOutput(status: 1, text: "no scripted output") }
        return self.outputs.removeFirst()
    }
}
