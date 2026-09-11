import Darwin
import Foundation
import ServiceManagement
import TaurineShared

enum HelperInstallStatus: Equatable {
    case installed
    case missing
    /// Registrado, mas aguardando o usuário habilitar em Ajustes do Sistema →
    /// Geral → Itens de Login e Extensões.
    case requiresApproval
}

/// Fachada testável sobre `SMAppService`, que não é injetável.
@MainActor
protocol DaemonRegistering: AnyObject {
    func register() throws
    func unregister() throws
    func status() -> SMAppService.Status
    func openSystemSettings()
}

@MainActor
final class SystemDaemonRegistrar: DaemonRegistering {
    private let service = SMAppService.daemon(plistName: HelperPaths.daemonPlistName)

    func register() throws { try self.service.register() }
    func unregister() throws { try self.service.unregister() }
    func status() -> SMAppService.Status { self.service.status }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class HelperInstaller {
    private let registrar: DaemonRegistering
    private let fileExists: (String) -> Bool
    private let run: (String, [String]) async throws -> CommandOutput

    init(
        registrar: DaemonRegistering? = nil,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        run: @escaping (String, [String]) async throws -> CommandOutput = { _, arguments in
            await AppleScriptRunner.run(arguments.count > 1 ? arguments[1] : "")
        }
    ) {
        self.registrar = registrar ?? SystemDaemonRegistrar()
        self.fileExists = fileExists
        self.run = run
    }

    static func status(of status: SMAppService.Status) -> HelperInstallStatus {
        switch status {
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .missing
        @unknown default: return .missing
        }
    }

    func status() -> HelperInstallStatus { Self.status(of: self.registrar.status()) }

    /// Verdadeiro enquanto restar a instalação anterior a `SMAppService`, que
    /// precisa sair antes do registro: usa o mesmo Label e MachService.
    var hasLegacyInstallation: Bool { self.fileExists(HelperPaths.legacyPlist) }

    func install() async throws {
        if self.hasLegacyInstallation { try await self.removeLegacyInstallation() }
        do {
            try self.registrar.register()
        } catch let error as NSError {
            // Já registrado não é erro: o app pode ter sido reinstalado sobre um
            // registro vivo. O status abaixo decide se ainda falta aprovação.
            guard error.code == kSMErrorAlreadyRegistered else { throw Self.installError(for: error) }
        }
        guard self.status() != .missing else { throw PowerError.helperNotInstalled }
    }

    func remove() async throws {
        // O legado pode coexistir com o registro novo se um upgrade foi
        // interrompido; limpar os dois mantém a remoção idempotente.
        if self.hasLegacyInstallation { try await self.removeLegacyInstallation() }
        do {
            try self.registrar.unregister()
        } catch let error as NSError {
            // `notFound` aqui é sucesso: não havia registro para remover.
            guard error.code == kSMErrorJobNotFound else { throw Self.installError(for: error) }
        }
    }

    func openSystemSettings() { self.registrar.openSystemSettings() }

    private func removeLegacyInstallation() async throws {
        let output = try await self.run("/usr/bin/osascript", ["-e", Self.appleScript(for: Self.removalScript())])
        if output.text == "TAURINE_AUTH_CANCELLED" { throw PowerError.cancelled }
        guard output.status == 0 else { throw PowerError.commandFailed(output.text) }
    }

    private static func installError(for error: NSError) -> PowerError {
        switch error.code {
        // Negar a autorização não é falha: preserva o fluxo de cancelamento.
        case kSMErrorAuthorizationFailure, kSMErrorLaunchDeniedByUser:
            return .cancelled
        case kSMErrorInvalidSignature:
            return .commandFailed(String(localized: "This copy of Taurine is not correctly signed, so it cannot control sleep."))
        default:
            return .commandFailed(error.localizedDescription)
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Desinstala o daemon anterior a `SMAppService`. O `pmset` vem primeiro: é a
    /// única coisa que destrava uma máquina deixada acordada pelo helper antigo.
    nonisolated static func removalScript() -> String {
        """
        set -u
        export LC_ALL=C
        /usr/bin/pmset -a disablesleep 0 || true
        /bin/launchctl bootout system/\(HelperPaths.label) 2>/dev/null || true
        /bin/rm -f \(HelperPaths.legacyBinary) \(HelperPaths.legacyPlist)
        /bin/rm -rf \(HelperPaths.stateDirectory)
        """
    }

    nonisolated static func appleScript(for shellScript: String) -> String {
        let quoted = shellScript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        try
            do shell script "\(quoted)" with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "TAURINE_AUTH_CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
    }
}
