import Foundation
import TaurineShared

final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let sleep: SleepControl
    private let tracker = SessionTracker()

    init(sleep: SleepControl) {
        self.sleep = sleep
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let executable = ConnectionPolicy.executablePath(of: connection.processIdentifier)
        let bundleID = executable.flatMap(ConnectionPolicy.bundleIdentifier(ofExecutableAt:))
        guard ConnectionPolicy.accepts(peerUID: connection.effectiveUserIdentifier, consoleUID: ConnectionPolicy.consoleUser(), bundleIdentifier: bundleID) else {
            return false
        }
        let token = SessionToken()
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = ConnectionHandler(token: token, sleep: self.sleep, tracker: self.tracker)
        let ended: @Sendable () -> Void = { [sleep, tracker] in
            Task { await Self.connectionEnded(token, sleep: sleep, tracker: tracker) }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        connection.resume()
        return true
    }

    // Fallback de segurança: o app morreu sem desativar. Cobre crash, SIGKILL e logout.
    static func connectionEnded(_ token: SessionToken, sleep: SleepControl, tracker: SessionTracker) async {
        guard await tracker.end(token) else { return }
        await SleepRevert.revertIfDisabled(sleep)
    }
}

/// Reverte `disablesleep` quando ninguém mais é dono da sessão. Erros são
/// engolidos de propósito: é caminho de limpeza, não há a quem reportar.
enum SleepRevert {
    static func revertIfDisabled(_ sleep: SleepControl) async {
        // Unknown state counts as "needs revert": a failed read after a successful
        // `disablesleep 1` write would otherwise strand the Mac awake with no owner.
        if (try? await sleep.isDisabled()) != false {
            try? await sleep.setDisabled(false)
        }
    }
}

final class ConnectionHandler: NSObject, HelperProtocol, @unchecked Sendable {
    private let token: SessionToken
    private let sleep: SleepControl
    private let tracker: SessionTracker
    private let stateDirectory: String

    init(token: SessionToken, sleep: SleepControl, tracker: SessionTracker, stateDirectory: String = HelperPaths.stateDirectory) {
        self.token = token
        self.sleep = sleep
        self.tracker = tracker
        self.stateDirectory = stateDirectory
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(HelperVersion.current)
    }

    func sleepIsDisabled(reply: @escaping (NSNumber?, NSError?) -> Void) {
        Task {
            do { reply(NSNumber(value: try await self.sleep.isDisabled()), nil) }
            catch { reply(nil, Self.bridge(error)) }
        }
    }

    func setSleepDisabled(_ disabled: Bool, appPath: String, reply: @escaping (NSError?) -> Void) {
        Task {
            var acquiredNow = false
            if disabled {
                switch await self.tracker.begin(self.token) {
                case .acquired: acquiredNow = true
                case .alreadyOwner: break
                case .busy:
                    reply(HelperFailure(code: .busy).nsError)
                    return
                }
            } else {
                // Releasing is allowed with no owner (recovery from an external
                // `disablesleep 1`), but never over another connection's block.
                guard await self.tracker.canRelease(self.token) else {
                    reply(HelperFailure(code: .busy).nsError)
                    return
                }
            }
            do {
                try await self.sleep.setDisabled(disabled)
                self.recordAppPath(appPath)
                if !disabled { _ = await self.tracker.end(self.token) }
                reply(nil)
            } catch {
                // Rollback só do que esta chamada criou: se já éramos donos, o
                // bloqueio anterior continua válido e não pode ser desfeito.
                if acquiredNow {
                    await SleepRevert.revertIfDisabled(self.sleep)
                    _ = await self.tracker.end(self.token)
                }
                reply(Self.bridge(error))
            }
        }
    }

    private static func bridge(_ error: Error) -> NSError {
        (error as? HelperFailure ?? HelperFailure(code: .commandFailed, message: error.localizedDescription)).nsError
    }

    // The path comes from the client: only record a plausible bundle path. A bad
    // path is skipped silently, the pmset change it accompanied already succeeded.
    private func recordAppPath(_ path: String) {
        guard path.hasPrefix("/"), (path as NSString).pathExtension == "app" else { return }
        let manager = FileManager.default
        try? manager.createDirectory(atPath: self.stateDirectory, withIntermediateDirectories: true)
        // createDirectory(attributes:) não reaplica o modo em diretório existente.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.stateDirectory)
        let file = (self.stateDirectory as NSString).appendingPathComponent((HelperPaths.appPathFile as NSString).lastPathComponent)
        try? Data((path + "\n").utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
