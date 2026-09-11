import Foundation
import TaurineShared

/// Reverte `disablesleep` quando o app desaparece com o bloqueio ativo.
///
/// Com `SMAppService` o daemon roda de dentro do bundle, então apagar o app o
/// impede de subir no boot seguinte — sem isto o Mac ficaria acordado para
/// sempre. Cobre também `mv` para outro volume e remoção por outra conta.
enum BundleWatchdog {
    static let interval = Duration.seconds(60)
    /// Espera antes de confirmar a ausência do bundle. Atualizar o app o remove
    /// por instantes; sem a segunda amostra o watchdog desligaria o bloqueio de
    /// uma sessão viva no meio de um update.
    static let confirmationDelay = Duration.seconds(5)

    /// Caminho do bundle derivado do executável, subindo os três níveis de
    /// `Contents/Library/LaunchDaemons`. Derivar (em vez de receber do app)
    /// mantém o watchdog independente de qualquer mensagem XPC.
    static func bundlePath(executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) -> String? {
        let resolved = (executablePath as NSString).resolvingSymlinksInPath
        var directory = (resolved as NSString).deletingLastPathComponent
        for _ in 0 ..< 3 {
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard (directory as NSString).pathExtension == "app" else { return nil }
        return directory
    }

    static func run(
        sleep: SleepControl,
        tracker: SessionTracker,
        bundlePath: String?,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: Self.interval) },
        confirm: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: Self.confirmationDelay) }
    ) async {
        // Sem caminho reconhecível não há o que vigiar: um falso positivo aqui
        // desligaria o bloqueio de um usuário com a sessão ativa.
        guard let bundlePath else { return }
        while !Task.isCancelled {
            do { try await wait() } catch { return }
            // O daemon vive desde o boot (RunAtLoad), mas só há o que reverter
            // enquanto alguém detém a sessão.
            guard await tracker.hasOwner, !exists(bundlePath) else { continue }
            do { try await confirm() } catch { return }
            guard !exists(bundlePath) else { continue }
            await SleepRevert.revertIfDisabled(sleep)
        }
    }
}
