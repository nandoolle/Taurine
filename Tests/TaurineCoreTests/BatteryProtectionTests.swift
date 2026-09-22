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
private final class FakeNotifier: StopNotifying {
    var reasons: [String] = []
    func requestAuthorization() {}
    func notifyBatteryStop(reason: String) { self.reasons.append(reason) }
}

@MainActor
final class BatteryProtectionTests: XCTestCase {
    func testBatteryCutoffNotifiesOnceWithTheStopReason() async {
        let battery = FakeBattery()
        let notifier = FakeNotifier()
        let session = PowerSession(settings: FakeSettings(), assertions: FakeAssertions(), battery: battery, notifier: notifier, helperStatus: { .installed })
        await session.activate(duration: nil)
        XCTAssertTrue(notifier.reasons.isEmpty, "ativar não notifica")
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(notifier.reasons, [session.automaticStopMessage])
        // Já parado: novas leituras baixas não repetem o aviso.
        await session.enforceBatteryLimit()
        XCTAssertEqual(notifier.reasons.count, 1)
    }

    func testManualDeactivationDoesNotNotify() async {
        let notifier = FakeNotifier()
        let session = PowerSession(settings: FakeSettings(), assertions: FakeAssertions(), battery: FakeBattery(), notifier: notifier, helperStatus: { .installed })
        await session.activate(duration: nil)
        await session.deactivate()
        XCTAssertTrue(notifier.reasons.isEmpty)
    }

    func testFailedCutoffDoesNotNotify() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        let notifier = FakeNotifier()
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, notifier: notifier, helperStatus: { .installed })
        await session.activate(duration: nil)
        settings.writeError = PowerError.commandFailed("password required")
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(notifier.reasons.isEmpty, "o sleep não foi liberado: nada a avisar")
    }

    func testDefaultThresholdAndBoundary() {
        XCTAssertEqual(BatteryPolicy.defaultThreshold, 25)
        XCTAssertNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 26, isOnBattery: true)), threshold: 25))
        XCTAssertNotNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 25, isOnBattery: true)), threshold: 25))
        XCTAssertNotNil(BatteryPolicy.stopReason(for: .battery(.init(percentage: 24, isOnBattery: true)), threshold: 25))
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
        battery.reading = .battery(.init(percentage: 25, isOnBattery: true))
        let assertions = FakeAssertions()
        let session = PowerSession(settings: settings, assertions: assertions, battery: battery, helperStatus: { .installed })
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
        let session = PowerSession(settings: settings, assertions: assertions, battery: battery, helperStatus: { .installed })
        await session.activate(duration: 300)
        battery.reading = .battery(.init(percentage: 25, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(assertions.held)
        XCTAssertNil(session.deadline)
        battery.reading = .battery(.init(percentage: 90, isOnBattery: false))
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
    }

    func testUnpluggingBelowThresholdTriggersCutoff() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 20, isOnBattery: false))
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, helperStatus: { .installed })
        await session.activate(duration: nil)
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
    }

    func testChangingThresholdAppliesToCurrentSession() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        var threshold = 60
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, batteryThreshold: { threshold }, helperStatus: { .installed })
        await session.activate(duration: nil)
        threshold = 85
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
    }

    func testReadFailureRestoresSleep() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, helperStatus: { .installed })
        await session.activate(duration: nil)
        battery.reading = .unavailable
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertNotNil(session.automaticStopMessage)
    }

    func testFailedCutoffStaysActiveAndRetriesWithoutPromptStorm() async {
        let settings = FakeSettings()
        let battery = FakeBattery()
        var now = Date(timeIntervalSince1970: 100)
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), now: { now }, battery: battery, helperStatus: { .installed })
        await session.activate(duration: nil)
        settings.writeError = PowerError.commandFailed("password required")
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        XCTAssertNil(session.errorMessage, "parada automática nunca abre janela")
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
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, helperStatus: { .installed })
        settings.onWrite = {
            battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
            await session.enforceBatteryLimit()
        }
        await session.activate(duration: nil)
        settings.onWrite = nil
        await session.enforceBatteryLimit()
        XCTAssertEqual(settings.writes, [true, false])
        XCTAssertEqual(session.state, .inactive)
    }

    // O resíduo de uma sessão anterior sai no revert de launch, sem depender da
    // política de bateria nem de ler o estado atual.
    func testLaunchRevertClearsLeftoverSleepBlock() async {
        let settings = FakeSettings()
        settings.disabled = true
        let battery = FakeBattery()
        battery.reading = .battery(.init(percentage: 20, isOnBattery: true))
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, helperStatus: { .installed })
        await session.revert()
        XCTAssertEqual(settings.writes, [false])
        XCTAssertEqual(session.state, .inactive)
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
        let session = PowerSession(settings: settings, assertions: FakeAssertions(), battery: battery, batteryProtectionEnabled: { enabled }, helperStatus: { .installed })
        await session.activate(duration: 300)
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .active)
        XCTAssertNotNil(session.deadline)
        enabled = true
        await session.enforceBatteryLimit()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertEqual(settings.writes, [true, false])
    }

}
