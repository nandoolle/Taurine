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

/// Quem pediu a abertura do app: só uma abertura deliberada deve trazer a
/// janela de Preferências à frente.
enum LaunchSource: Equatable {
    case user
    case automatic

    /// `NSApplicationLaunchIsDefaultLaunchKey` é `false` para toda abertura que
    /// não é um launch comum — login item, estado de sessão restaurado, abrir
    /// arquivo, Serviço. Nenhuma delas é o usuário pedindo o app, então todas
    /// entram em `.automatic`. Chave ausente conta como usuário: é o duplo clique.
    static func from(launchUserInfo: [AnyHashable: Any]?) -> LaunchSource {
        guard let isDefaultLaunch = launchUserInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool else { return .user }
        return isDefaultLaunch ? .user : .automatic
    }
}
