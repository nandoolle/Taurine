import Combine
import Foundation

@MainActor
final class PowerSession: ObservableObject {
    enum State { case inactive, active, needsHelper }

    @Published private(set) var state: State = .inactive
    @Published private(set) var isBusy = false
    @Published private(set) var deadline: Date?
    @Published var errorMessage: String?
    @Published private(set) var automaticStopMessage: String?
    @Published private(set) var helperOutdated = false

    private let settings: PowerSettings
    private let assertions: WakePreventing
    private let now: () -> Date
    private let battery: BatteryReadingProvider?
    private let batteryThreshold: () -> Int
    private let batteryProtectionEnabled: () -> Bool
    private let helperStatus: @MainActor () -> HelperInstallStatus
    private var lastSafetyAttempt: Date?

    init(settings: PowerSettings, assertions: WakePreventing, now: @escaping () -> Date = Date.init, battery: BatteryReadingProvider? = nil, batteryThreshold: @escaping () -> Int = { BatteryPolicy.defaultThreshold }, batteryProtectionEnabled: @escaping () -> Bool = { true }, helperStatus: @escaping @MainActor () -> HelperInstallStatus) {
        self.settings = settings
        self.assertions = assertions
        self.now = now
        self.battery = battery
        self.batteryThreshold = batteryThreshold
        self.batteryProtectionEnabled = batteryProtectionEnabled
        self.helperStatus = helperStatus
        self.state = helperStatus() == .installed ? .inactive : .needsHelper
    }

    /// Libera o sleep sem consultar o estado atual da máquina. Disparar sobre um
    /// Mac que já dorme não muda nada; ler antes só criaria um caminho de falha.
    func revert() async {
        guard !self.isBusy, self.helperStatus() == .installed else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        try? await self.settings.setSleepDisabled(false)
        try? self.assertions.release()
        self.deadline = nil
        if self.state == .active { self.state = .inactive }
    }

    func helperInstallationChanged() {
        let status = self.helperStatus()
        self.helperOutdated = false
        if status == .installed {
            if self.state == .needsHelper { self.state = .inactive }
        } else {
            // Sem helper ninguém muda o pmset: assertions saem.
            try? self.assertions.release()
            self.deadline = nil
            self.errorMessage = nil
            self.state = .needsHelper
        }
    }

    func activate(duration: TimeInterval?) async {
        guard !self.isBusy, self.state == .inactive || self.state == .active else { return }
        if self.batteryProtectionEnabled(), let battery, let reason = BatteryPolicy.stopReason(for: battery.read(), threshold: self.batteryThreshold()) {
            self.automaticStopMessage = reason
            if self.state == .active { await self.enforceBatteryLimit() }
            return
        }
        self.automaticStopMessage = nil
        self.lastSafetyAttempt = nil
        if self.state == .active {
            self.setDeadline(duration)
            return
        }
        self.isBusy = true
        self.errorMessage = nil
        defer { self.isBusy = false }
        do {
            try self.assertions.acquire()
            try await self.settings.setSleepDisabled(true)
            self.state = .active
            self.setDeadline(duration)
        } catch {
            try? self.assertions.release()
            self.deadline = nil
            self.report(error)
        }
    }

    @discardableResult
    func deactivate(reportErrors: Bool = true) async -> Bool {
        guard !self.isBusy else { return false }
        guard self.state != .inactive else { return true }
        self.isBusy = true
        self.deadline = nil // A failed automatic stop must not retry every second.
        if reportErrors { self.errorMessage = nil }
        defer { self.isBusy = false }
        do {
            try await self.settings.setSleepDisabled(false)
            try self.assertions.release()
            self.state = .inactive
            return true
        } catch {
            if case PowerError.helperOutdated = error {
                self.helperOutdated = true
                self.state = .needsHelper
                return false
            }
            if reportErrors { self.report(error) }
            return false
        }
    }

    func expireIfNeeded() async {
        guard self.state == .active, let deadline = self.deadline, deadline <= self.now() else { return }
        await self.deactivate(reportErrors: false)
    }

    func enforceBatteryLimit() async {
        guard self.batteryProtectionEnabled() else {
            self.lastSafetyAttempt = nil
            self.automaticStopMessage = nil
            return
        }
        guard !self.isBusy, self.state == .active, let battery else { return }
        guard let reason = BatteryPolicy.stopReason(for: battery.read(), threshold: self.batteryThreshold()) else { return }
        if let previous = self.lastSafetyAttempt, self.now().timeIntervalSince(previous) < 30 { return }
        self.lastSafetyAttempt = self.now()
        // Parada automática não é clique do usuário: falhar aqui não abre janela.
        if await self.deactivate(reportErrors: false) {
            self.automaticStopMessage = reason
            self.lastSafetyAttempt = nil
        }
    }

    private func setDeadline(_ duration: TimeInterval?) {
        self.deadline = duration.flatMap { $0 > 0 ? self.now().addingTimeInterval($0) : nil }
    }

    private func report(_ error: Error) {
        if case PowerError.helperOutdated = error {
            self.helperOutdated = true
            self.state = .needsHelper
            return
        }
        if case PowerError.cancelled = error { return }
        self.errorMessage = error.localizedDescription
    }
}
