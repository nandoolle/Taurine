import AppKit
import Foundation
import ServiceManagement

/// Registro do Taurine como item de login. O estado real vive no sistema, não
/// em UserDefaults: o usuário pode revogá-lo em Ajustes do Sistema.
enum LaunchAtStartup {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Erros são propagados: sem isto o toggle mentiria sobre o estado.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
