import Foundation
import UserNotifications

@MainActor
protocol StopNotifying {
    func requestAuthorization()
    func notifyBatteryStop(reason: String)
}

/// Default do `PowerSession`: mantém o Core utilizável sem bundle assinado.
struct SilentStopNotifier: StopNotifying {
    func requestAuthorization() {}
    func notifyBatteryStop(reason _: String) {}
}

/// Avisa que a proteção de bateria soltou o sleep.
///
/// A parada acontece justamente quando ninguém está na máquina — sem uma
/// notificação do sistema o motivo só apareceria no menu, para ninguém ver.
@MainActor
final class StopNotifier: StopNotifying {
    private let center: UNUserNotificationCenter?

    init() {
        // Fora de um bundle assinado o centro de notificações não existe e
        // instanciá-lo derruba o processo — testes e SwiftPM caem aqui.
        self.center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() {
        self.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyBatteryStop(reason: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Taurine stopped protecting sleep")
        content.body = reason
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
