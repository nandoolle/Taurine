// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import Combine
import IOKit.ps
import SwiftUI

@MainActor
class TaurineViewModel: ObservableObject {
    // Não é @Published de propósito: recalculado a cada segundo e não lido por
    // nenhuma view. Publicar reconstruía as Preferências 1x/s.
    private(set) var timeRemaining: TimeInterval?

    @Published private(set) var installingHelper = false
    private let installer = HelperInstaller()
    let session: PowerSession
    private let battery: SystemBattery
    private var batterySource: CFRunLoopSource?
    private var timer: Timer?
    private var ticks = 0
    private lazy var activationSound: NSSound? = Self.sound(named: "can-opening")
    private lazy var deactivationSound: NSSound? = Self.sound(named: "fizz-out")
    private let notifier: StopNotifying
    private var cancellables = Set<AnyCancellable>()

    var isActive: Bool { self.session.state == .active }
    var isBusy: Bool { self.installingHelper || self.session.isBusy }
    var needsHelper: Bool { self.session.state == .needsHelper }
    /// Instalação legada presente: o upgrade pede senha duas vezes (remoção do
    /// daemon antigo e registro do novo), então a UI avisa antes.
    var helperUpgradeNeedsTwoPrompts: Bool { self.installer.hasLegacyInstallation }
    var helperOutdated: Bool { self.session.helperOutdated }
    /// Registrado mas pendente de aprovação em Ajustes do Sistema. Estado
    /// próprio: a saída é o usuário habilitar lá, não reinstalar aqui.
    @Published private(set) var helperRequiresApproval = false

    private static func sound(named name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: false)
        sound?.volume = 0.15
        return sound
    }

    init(notifier: StopNotifying? = nil) {
        let notifier = notifier ?? StopNotifier()
        self.notifier = notifier
        UserDefaults.standard.register(defaults: [PreferenceKeys.batteryThreshold: BatteryPolicy.defaultThreshold, PreferenceKeys.batteryProtectionEnabled: true, PreferenceKeys.playActivationSound: true, PreferenceKeys.showInDock: false])
        let battery = SystemBattery()
        self.battery = battery
        let installer = self.installer
        self.helperRequiresApproval = installer.status() == .requiresApproval
        self.session = PowerSession(
            settings: HelperPowerSettings(), assertions: WakeAssertions(),
            battery: battery,
            batteryThreshold: { UserDefaults.standard.integer(forKey: PreferenceKeys.batteryThreshold) },
            batteryProtectionEnabled: { UserDefaults.standard.bool(forKey: PreferenceKeys.batteryProtectionEnabled) },
            notifier: notifier,
            helperStatus: { installer.status() }
        )
        self.session.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &self.cancellables)
        self.session.$state
            .removeDuplicates()
            .scan((PowerSession.State.inactive, PowerSession.State.inactive)) { ($0.1, $1) }
            .sink { [weak self] previous, state in
                if state == .active, UserDefaults.standard.bool(forKey: PreferenceKeys.keepAppsActive) {
                    ActivitySimulator.shared.startMonitoring()
                } else {
                    ActivitySimulator.shared.stopMonitoring()
                }
                // Um único ponto para todas as paradas: clique, prazo vencido,
                // bateria e perda do helper passam por esta transição.
                if previous == .active, state != .active { self?.playDeactivationSound() }
            }
            .store(in: &self.cancellables)

        // O usuário aprova o daemon em Ajustes do Sistema e volta: sem reconsultar
        // aqui a UI ficaria presa em "precisa de aprovação".
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.recheckHelperApproval() }
            }
            .store(in: &self.cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkBattery()
                    await self?.session.expireIfNeeded()
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
        self.batterySource = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("TaurineBatteryChanged"), object: nil)
            }
        }, nil)?.takeRetainedValue()
        if let source = self.batterySource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        Task {
            // O launch sempre parte de um Mac que dorme: reverter sem ler
            // conserta em silêncio o resíduo de um encerramento anormal.
            await self.session.revert()
            await self.checkBattery()
            if self.session.state == .inactive, UserDefaults.standard.bool(forKey: PreferenceKeys.activateAtLaunch) {
                self.activate()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.installingHelper else { return }
                self.timeRemaining = self.session.deadline.map { max(0, $0.timeIntervalSinceNow) }
                if self.ticks % 5 == 0 { await self.checkBattery() }
                await self.session.expireIfNeeded()
                self.ticks += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func toggleActive() {
        guard !self.isBusy else { return }
        if self.isActive {
            self.deactivate()
        } else {
            self.activate()
        }
    }

    func activate(withTimeout timeout: TimeInterval? = nil) {
        let duration = timeout.map { $0 > 0 ? $0 : 0 } ?? self.defaultDuration
        Task {
            guard await self.ensureSleepControlAvailable() else { return }
            self.requestNotificationAuthorizationOnce()
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
        // Sair sempre é permitido: falhar em reverter aqui prenderia o usuário
        // num app que ele não consegue fechar. O boot seguinte cobre o resíduo.
        await self.session.revert()
        self.timer?.invalidate()
        if let source = self.batterySource { CFRunLoopSourceInvalidate(source) }
        self.batterySource = nil
        ActivitySimulator.shared.stopMonitoring()
        return true
    }

    func checkBattery() async {
        guard !self.installingHelper else { return }
        await self.session.enforceBatteryLimit()
    }

    private func requestNotificationAuthorizationOnce() {
        guard !UserDefaults.standard.bool(forKey: PreferenceKeys.didRequestNotifications) else { return }
        UserDefaults.standard.set(true, forKey: PreferenceKeys.didRequestNotifications)
        self.notifier.requestAuthorization()
    }

    private func playDeactivationSound() {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.playActivationSound) else { return }
        self.deactivationSound?.stop()
        self.deactivationSound?.play()
    }

    func batteryThresholdChanged() {
        Task { await self.checkBattery() }
    }

    /// Registra o daemon na primeira ativação. O usuário pede para manter o Mac
    /// acordado; o componente que faz isso é detalhe de implementação.
    private func ensureSleepControlAvailable() async -> Bool {
        if self.installer.status() == .installed { return true }
        self.installingHelper = true
        defer { self.installingHelper = false }
        do {
            try await self.installer.install()
        } catch PowerError.cancelled {
            return false
        } catch {
            self.session.errorMessage = error.localizedDescription
            return false
        }
        self.helperRequiresApproval = self.installer.status() == .requiresApproval
        self.session.helperInstallationChanged()
        // Registrar não conclui nada visível: sem abrir os Ajustes o clique do
        // usuário morre em silêncio, sem dizer que falta aprovar nem onde.
        if self.helperRequiresApproval { self.openHelperSystemSettings() }
        return self.installer.status() == .installed
    }

    func openHelperSystemSettings() { self.installer.openSystemSettings() }

    private func recheckHelperApproval() async {
        guard !self.installingHelper else { return }
        let status = self.installer.status()
        self.helperRequiresApproval = status == .requiresApproval
        guard status == .installed, self.needsHelper else { return }
        self.session.helperInstallationChanged()
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
        if self.helperRequiresApproval { return String(localized: "Waiting for your approval") }
        // needsHelper não tem texto próprio: sem daemon o Taurine está apenas
        // inativo, e ativar cuida do registro.
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
    static let didRequestNotifications = "TaurineDidRequestNotifications"
    static let batteryProtectionEnabled = "TaurineBatteryProtectionEnabled"
    static let batteryThreshold = "TaurineBatteryThreshold"
    static let activateAtLaunch = "TaurineActivateAtLaunch"
    static let defaultDuration = "TaurineDefaultDuration"
    static let keepAppsActive = "TaurineKeepAppsActive"
    static let showInDock = "TaurineShowInDock"
}
