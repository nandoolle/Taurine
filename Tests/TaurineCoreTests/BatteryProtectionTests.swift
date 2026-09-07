import Foundation
import IOKit.ps
import XCTest
@testable import TaurineCore

@MainActor
private final class FakeBattery: BatteryReadingProvider {
    var reading: BatteryReading = .battery(BatteryStatus(percentage: 80, isOnBattery: true))
    func read() -> BatteryReading { self.reading }
}

@MainActor
final class BatteryProtectionTests: XCTestCase {
    func testDefaultThresholdAndBoundary() {
        XCTAssertEqual(BatteryPolicy.defaultThreshold, 60)
        XCTAssertNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 61, isOnBattery: true)), threshold: 60))
        XCTAssertNotNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 60, isOnBattery: true)), threshold: 60))
        XCTAssertNotNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 59, isOnBattery: true)), threshold: 60))
    }

    func testExternalPowerAndNoBatteryDoNotTriggerCutoff() {
        XCTAssertNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 5, isOnBattery: false)), threshold: 60))
        XCTAssertNil(BatteryPolicy.stopReason(for: .noBattery, threshold: 60))
        XCTAssertNotNil(BatteryPolicy.stopReason(for: .unavailable, threshold: 60))
    }

    func testThresholdCannotBeDisabledByInvalidStoredValue() {
        XCTAssertEqual(BatteryPolicy.threshold(0), 1)
        XCTAssertEqual(BatteryPolicy.threshold(120), 100)
        XCTAssertEqual(BatteryPolicy.threshold(60), 60)
    }

    func testCapacityNormalizationAndInternalBatteryFiltering() {
        let reading = SystemBattery.parse([
            [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 1, kIOPSMaxCapacityKey: 100],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 30,
             kIOPSMaxCapacityKey: 50, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
        ])
        XCTAssertEqual(reading, .battery(.init(percentage: 60, isOnBattery: true)))
        XCTAssertEqual(SystemBattery.parse([]), .noBattery)
        XCTAssertEqual(SystemBattery.parse([[kIOPSTypeKey: kIOPSInternalBatteryType]]), .unavailable)
        XCTAssertEqual(SystemBattery.parse([[kIOPSTypeKey: kIOPSInternalBatteryType,
                                             kIOPSCurrentCapacityKey: 20, kIOPSMaxCapacityKey: 0,
                                             kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]]), .unavailable)
    }

    func testLowBatteryPreventsActivationBeforePrivilegedCommand() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 60, isOnBattery: true))
        let assertions = FakeAssertions()
        let session = PowerSession(settings: settings, assertions: assertions, journal: FakeJournal(), battery: battery)
        await session.refresh()
        await session.activate(duration: nil)
        XCTAssertEqual(session.state, .inactive)
        XCTAssertTrue(settings.writes.isEmpty)
        XCTAssertFalse(assertions.held)
        XCTAssertNotNil(session.automaticStopMessage)
    }

    func testCutoffRestoresSettingReleasesAssertionsAndDoesNotReactivate() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        let assertions = FakeAssertions()
        let journal = FakeJournal()
        let session = PowerSession(settings: settings, assertions: assertions, journal: journal, battery: battery)
        await session.refresh()
        await session.activate(duration: 300)
        battery.reading = .battery(.init(percentage: 60, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(journal.pending)
        XCTAssertNil(session.deadline)
        battery.reading = .battery(.init(percentage: 90, isOnBattery: false))
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
    }

    func testUnpluggingBelowThresholdTriggersCutoff() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 40, isOnBattery: false))
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery)
        await session.refresh()
        await session.activate(duration: nil)
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        battery.reading = .battery(.init(percentage: 40, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
    }

    func testChangingThresholdAppliesToCurrentSession() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        var threshold = 60
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery, batteryThreshold: { threshold })
        await session.refresh()
        await session.activate(duration: nil)
        threshold = 85
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
    }

    func testReadFailureRestoresSleep() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery)
        await session.refresh()
        await session.activate(duration: nil)
        battery.reading = .unavailable
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertNotNil(session.automaticStopMessage)
    }

    func testFailedCutoffRemainsRecoveryAndRetriesWithoutPromptStorm() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        var now = Date(timeIntervalSince1970: 100)
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), now: { now }, battery: battery)
        await session.refresh()
        await session.activate(duration: nil)
        settings.writeError = PowerError.authorizationRequired
        battery.reading = .battery(.init(percentage: 50, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .recovery)
        XCTAssertNotNil(session.errorMessage)
        session.errorMessage = nil
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        now = now.addingTimeInterval(31)
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false, false])
        XCTAssertNil(session.errorMessage)
        settings.writeError = nil
        now = now.addingTimeInterval(31)
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
    }

    func testBusyBatteryEventIsRecheckedAfterOperation() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery)
        await session.refresh()
        settings.onWrite = {
            battery.reading = .battery(.init(percentage: 55, isOnBattery: true))
            await session.enforceBatteryLimit()
        }
        await session.activate(duration: nil)
        settings.onWrite = nil
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
    }

    func testRestartRecoveryAlsoHonorsBatteryLimit() async {
        let settings = FakeSettings()
        settings.disabled = true
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery)
        await session.refresh()
        XCTAssertEqual(session.state, .recovery)
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [false])
        XCTAssertEqual(session.state, .inactive)
    }

    func testPermissionRuleAndInstallerSyntax() async throws {
        let rule = PermanentAuthorization.rule(for: 501)
        XCTAssertEqual(rule, "#501 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = directory.appendingPathComponent("policy")
        try rule.write(to: policy, atomically: true, encoding: .utf8)
        let parsed = try await CommandRunner.run("/usr/sbin/visudo", arguments: ["-cf", policy.path])
        XCTAssertEqual(parsed.status, 0, parsed.text)
        for removing in [false, true] {
            let path = directory.appendingPathComponent("installer.sh")
            try PermanentAuthorization.installationScript(uid: 501, removing: removing).write(to: path, atomically: true, encoding: .utf8)
            let syntax = try await CommandRunner.run("/bin/sh", arguments: ["-n", path.path])
            XCTAssertEqual(syntax.status, 0, syntax.text)
        }
    }
    func testThresholdInputAcceptsOnlyASCIIDigitsAndBounds() {
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText("abc"), "")
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText("6a0%"), "60")
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText("0"), "1")
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText("101"), "100")
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText(String(repeating: "9", count: 100)), "100")
        XCTAssertEqual(BatteryPolicy.sanitizedThresholdText("６０"), "")
    }

    func testDisablingBatteryProtectionAllowsLowBatteryAndReenablingStops() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        var enabled = false
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), journal: FakeJournal(), battery: battery, batteryProtectionEnabled: { enabled })
        await session.refresh()
        await session.activate(duration: 300)
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        XCTAssertNotNil(session.deadline)
        enabled = true
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertEqual(settings.writes, [true, false])
    }

    func testOptionalAuthorizationPromptsForBothChanges() async throws {
        var scripts: [String] = []
        let controller = PMSetController(run: { executable, arguments in
            if executable == "/usr/bin/sudo" { return CommandOutput(status: 1, text: "password required") }
            XCTAssertEqual(executable, "/usr/bin/osascript")
            scripts.append(arguments[1])
            return CommandOutput(status: 0, text: "")
        }, authorizationConfigured: { false })
        try await controller.setSleepDisabled(true)
        try await controller.setSleepDisabled(false)
        XCTAssertEqual(scripts, [
            "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges",
            "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges"
        ])
    }

    func testBackgroundRetryDoesNotRequestPassword() async {
        var calls = 0
        let controller = PMSetController(run: { executable, _ in
            calls += 1
            XCTAssertEqual(executable, "/usr/bin/sudo")
            return CommandOutput(status: 1, text: "password required")
        }, authorizationConfigured: { false })
        do {
            try await controller.setSleepDisabled(false, allowPrompt: false)
            XCTFail("Expected authorizationRequired")
        } catch PowerError.authorizationRequired {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
    }

    func testPermanentAuthorizationDoesNotPrompt() async throws {
        let controller = PMSetController(run: { executable, _ in
            XCTAssertEqual(executable, "/usr/bin/sudo")
            return CommandOutput(status: 0, text: "")
        }, authorizationConfigured: { true })
        try await controller.setSleepDisabled(true)
        try await controller.setSleepDisabled(false)
    }

    func testPasswordCancellationIsReported() async {
        let controller = PMSetController(run: { executable, _ in
            CommandOutput(status: 1, text: executable == "/usr/bin/osascript" ? "User canceled. (-128)" : "password required")
        }, authorizationConfigured: { false })
        do {
            try await controller.setSleepDisabled(true)
            XCTFail("Expected cancellation")
        } catch PowerError.cancelled {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

}
