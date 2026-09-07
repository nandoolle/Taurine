import Combine
import Foundation

@MainActor
final class PowerSession: ObservableObject {
    enum State { case checking, inactive, active, recovery }

    @Published private(set) var state: State = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var deadline: Date?
    @Published var errorMessage: String?
    @Published private(set) var automaticStopMessage: String?

    private let settings: PowerSettings
    private let assertions: WakePreventing
    private let journal: SessionJournaling
    private let now: () -> Date
    private let battery: BatteryReadingProvider?
    private let batteryThreshold: () -> Int
    private let batteryProtectionEnabled: () -> Bool
    private var lastSafetyAttempt: Date?

    init(settings: PowerSettings, assertions: WakePreventing, journal: SessionJournaling, now: @escaping () -> Date = Date.init, battery: BatteryReadingProvider? = nil, batteryThreshold: @escaping () -> Int = { BatteryPolicy.defaultThreshold }, batteryProtectionEnabled: @escaping () -> Bool = { true }) {
        self.settings = settings
        self.assertions = assertions
        self.journal = journal
        self.now = now
        self.battery = battery
        self.batteryThreshold = batteryThreshold
        self.batteryProtectionEnabled = batteryProtectionEnabled
    }

    var requiresRestoration: Bool { self.state == .active || self.state == .recovery }

    func refresh() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            if try await self.settings.sleepIsDisabled() {
                if self.state != .active { self.state = .recovery }
            } else {
                try self.assertions.release()
                try self.journal.setPending(false)
                self.deadline = nil
                self.state = .inactive
            }
        } catch {
            let shouldReport = self.state != .recovery
            self.state = .recovery
            self.deadline = nil
            if shouldReport { self.errorMessage = error.localizedDescription }
        }
    }

    func activate(duration: TimeInterval?) async {
        guard !self.isBusy, self.state == .inactive || self.state == .active else { return }
        if self.batteryProtectionEnabled(), let battery, let reason = BatteryPolicy.stopReason(for: battery.read(), threshold: self.batteryThreshold()) {
            self.automaticStopMessage = reason
            if self.requiresRestoration { await self.enforceBatteryLimit() }
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
            // Persist before pmset: a crash after this point must never look
            // like a completed session. Startup also checks the actual setting.
            try self.journal.setPending(true)
            try await self.settings.setSleepDisabled(true)
            guard try await self.settings.sleepIsDisabled() else { throw PowerError.verificationFailed }
            self.state = .active
            self.setDeadline(duration)
        } catch {
            await self.reconcileFailure(error)
        }
    }

    @discardableResult
    func deactivate(reportErrors: Bool = true, allowPrompt: Bool = true) async -> Bool {
        guard !self.isBusy else { return false }
        guard self.state != .inactive else { return true }
        self.isBusy = true
        self.deadline = nil // A failed automatic stop must not retry every second.
        if reportErrors { self.errorMessage = nil }
        defer { self.isBusy = false }
        do {
            try await self.settings.setSleepDisabled(false, allowPrompt: allowPrompt)
            guard try await !self.settings.sleepIsDisabled() else { throw PowerError.verificationFailed }
            try self.assertions.release()
            try self.journal.setPending(false)
            self.state = .inactive
            return true
        } catch {
            await self.reconcileFailure(error, reportErrors: reportErrors)
            return self.state == .inactive
        }
    }

    func expireIfNeeded() async {
        guard self.state == .active, let deadline = self.deadline, deadline <= self.now() else { return }
        await self.deactivate()
    }

    func enforceBatteryLimit() async {
        guard self.batteryProtectionEnabled() else {
            self.lastSafetyAttempt = nil
            self.automaticStopMessage = nil
            return
        }
        guard !self.isBusy, self.requiresRestoration, let battery else { return }
        guard let reason = BatteryPolicy.stopReason(for: battery.read(), threshold: self.batteryThreshold()) else { return }
        if let previous = self.lastSafetyAttempt, self.now().timeIntervalSince(previous) < 30 { return }
        let isFirstAttempt = self.lastSafetyAttempt == nil
        self.lastSafetyAttempt = self.now()
        if await self.deactivate(reportErrors: isFirstAttempt, allowPrompt: isFirstAttempt) {
            self.automaticStopMessage = reason
            self.lastSafetyAttempt = nil
        }
    }

    private func setDeadline(_ duration: TimeInterval?) {
        self.deadline = duration.flatMap { $0 > 0 ? self.now().addingTimeInterval($0) : nil }
    }

    private func reconcileFailure(_ error: Error, reportErrors: Bool = true) async {
        self.deadline = nil
        do {
            if try await self.settings.sleepIsDisabled() {
                self.state = .recovery
            } else {
                try self.assertions.release()
                try self.journal.setPending(false)
                self.state = .inactive
            }
        } catch {
            // An unreadable state is unsafe to label "off".
            self.state = .recovery
        }
        if case PowerError.cancelled = error, self.state == .inactive { return }
        if reportErrors { self.errorMessage = error.localizedDescription }
    }
}
