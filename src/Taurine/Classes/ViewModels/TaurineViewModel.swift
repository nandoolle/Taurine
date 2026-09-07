// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import Combine
import IOKit.ps
import SwiftUI

@MainActor
class TaurineViewModel: ObservableObject {
    @Published var showPreferences = false
    @Published private(set) var timeRemaining: TimeInterval?

    @Published private(set) var batteryReading: BatteryReading = .unavailable
    @Published private(set) var authorizationConfigured = PermanentAuthorization.isConfigured
    @Published private(set) var configuringAuthorization = false
    let session: PowerSession
    private let battery: SystemBattery
    private var batterySource: CFRunLoopSource?
    private var timer: Timer?
    private var ticks = 0
    private lazy var activationSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "can-opening", withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: false)
        sound?.volume = 0.15
        return sound
    }()
    private var cancellables = Set<AnyCancellable>()

    var isActive: Bool { self.session.state == .active }
    var needsRecovery: Bool { self.session.state == .recovery }
    var isBusy: Bool { self.configuringAuthorization || self.session.isBusy || self.session.state == .checking }

    init() {
        UserDefaults.standard.register(defaults: [PreferenceKeys.batteryThreshold: BatteryPolicy.defaultThreshold, PreferenceKeys.batteryProtectionEnabled: true, PreferenceKeys.playActivationSound: true])
        let battery = SystemBattery()
        self.battery = battery
        self.session = PowerSession(
            settings: PMSetController(), assertions: WakeAssertions(), journal: SessionJournal(),
            battery: battery,
            batteryThreshold: { UserDefaults.standard.integer(forKey: PreferenceKeys.batteryThreshold) },
            batteryProtectionEnabled: { UserDefaults.standard.bool(forKey: PreferenceKeys.batteryProtectionEnabled) }
        )
        self.session.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &self.cancellables)
        self.session.$state
            .removeDuplicates()
            .sink { state in
                if state == .active, UserDefaults.standard.bool(forKey: PreferenceKeys.keepAppsActive) {
                    ActivitySimulator.shared.startMonitoring()
                } else {
                    ActivitySimulator.shared.stopMonitoring()
                }
            }
            .store(in: &self.cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkBattery()
                    await self?.session.expireIfNeeded()
                    await self?.session.refresh()
                }
            }
            .store(in: &self.cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("TaurineBatteryChanged"))
            .sink { [weak self] _ in
                Task { @MainActor in await self?.checkBattery() }
            }
            .store(in: &self.cancellables)

    }

    // Called after menu observers are installed, so launch errors and welcome
    // UI cannot be lost during controller initialization.
    func start() {
        self.showPreferences = !UserDefaults.standard.bool(forKey: PreferenceKeys.suppressLaunchMessage)
        self.batterySource = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("TaurineBatteryChanged"), object: nil)
            }
        }, nil)?.takeRetainedValue()
        if let source = self.batterySource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        Task {
            await self.session.refresh()
            await self.checkBattery()
            if self.session.state == .inactive, UserDefaults.standard.bool(forKey: PreferenceKeys.activateAtLaunch) {
                self.activate()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.configuringAuthorization else { return }
                self.timeRemaining = self.session.deadline.map { max(0, $0.timeIntervalSinceNow) }
                if self.ticks % 5 == 0 { await self.checkBattery() }
                await self.session.expireIfNeeded()
                self.ticks += 1
                if self.ticks % 15 == 0 { await self.session.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func toggleActive() {
        guard !self.isBusy else { return }
        if self.session.requiresRestoration {
            self.deactivate()
        } else {
            self.activate()
        }
    }

    func activate(withTimeout timeout: TimeInterval? = nil) {
        let duration = timeout.map { $0 > 0 ? $0 : 0 } ?? self.defaultDuration
        Task {
            let wasActive = self.isActive
            await self.session.activate(duration: duration)
            if !wasActive, self.isActive, UserDefaults.standard.bool(forKey: PreferenceKeys.playActivationSound) {
                self.activationSound?.stop()
                self.activationSound?.play()
            }
        }
    }

    func deactivate() {
        Task { await self.session.deactivate() }
    }

    func prepareToQuit() async -> Bool {
        guard !self.isBusy else { return false }
        // Refresh even when idle: another process may have changed pmset.
        await self.session.refresh()
        if self.session.requiresRestoration {
            guard await self.session.deactivate() else { return false }
        }
        self.timer?.invalidate()
        if let source = self.batterySource { CFRunLoopSourceInvalidate(source) }
        self.batterySource = nil
        ActivitySimulator.shared.stopMonitoring()
        return true
    }

    func checkBattery() async {
        self.batteryReading = self.battery.read()
        guard !self.configuringAuthorization else { return }
        await self.session.enforceBatteryLimit()
    }

    func batteryThresholdChanged() {
        Task { await self.checkBattery() }
    }

    func configureAuthorization(removing: Bool = false) {
        guard !self.isBusy else { return }
        self.configuringAuthorization = true
        Task {
            defer {
                self.authorizationConfigured = PermanentAuthorization.isConfigured
                self.configuringAuthorization = false
            }
            if removing {
                await self.session.refresh()
                guard await self.session.deactivate() else { return }
            }
            do {
                try await PermanentAuthorization().configure(removing: removing)
                if !removing { await self.session.enforceBatteryLimit() }
            } catch PowerError.cancelled {
                // A cancelled setup leaves the protection visibly unconfigured.
            } catch {
                self.session.errorMessage = error.localizedDescription
            }
        }
    }

    var batteryStatusText: String {
        switch self.batteryReading {
        case let .battery(status):
            let format = String(localized: "Current battery: %d%%")
            return String.localizedStringWithFormat(format, status.percentage)
        case .noBattery:
            return String(localized: "No internal battery")
        case .unavailable:
            return String(localized: "Battery level unavailable")
        }
    }

    func updateActivitySimulation(enabled: Bool) {
        if enabled { ActivitySimulator.shared.requestPermission() }
        if enabled, self.isActive {
            ActivitySimulator.shared.startMonitoring()
        } else {
            ActivitySimulator.shared.stopMonitoring()
        }
    }

    func formattedTimeRemaining() -> String? {
        if self.isBusy { return String(localized: "Updating sleep settings…") }
        if self.needsRecovery { return String(localized: "Sleep needs to be restored") }
        guard self.isActive else { return self.session.automaticStopMessage ?? String(localized: "Taurine is inactive") }
        if let remaining = self.session.deadline?.timeIntervalSinceNow, remaining > 0 {
            let seconds = Int(ceil(remaining))
            if seconds >= 3600 {
                return String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
            } else if seconds > 60 {
                return String.localizedStringWithFormat(String(localized: "%d minutes"), seconds / 60)
            } else {
                return String.localizedStringWithFormat(String(localized: "%d seconds"), seconds)
            }
        }
        return String(localized: "Taurine is active")
    }

    private var defaultDuration: TimeInterval {
        TimeInterval(max(0, UserDefaults.standard.integer(forKey: PreferenceKeys.defaultDuration))) * 60
    }
}

enum PreferenceKeys {
    static let playActivationSound = "TaurinePlayActivationSound"
    static let batteryProtectionEnabled = "TaurineBatteryProtectionEnabled"
    static let batteryThreshold = "TaurineBatteryThreshold"
    static let activateAtLaunch = "TaurineActivateAtLaunch"
    static let defaultDuration = "TaurineDefaultDuration"
    static let suppressLaunchMessage = "TaurineSuppressLaunchMessage"
    static let keepAppsActive = "TaurineKeepAppsActive"
}
