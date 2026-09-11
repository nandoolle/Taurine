import Foundation
import os
import OSLog
import TaurineShared

let helperLog = Logger(subsystem: HelperPaths.label, category: "xpc")

final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let sleep: SleepControl
    let tracker = SessionTracker()

    init(sleep: SleepControl) {
        self.sleep = sleep
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let executable = ConnectionPolicy.executablePath(of: connection.processIdentifier)
        let bundleID = executable.flatMap(ConnectionPolicy.bundleIdentifier(ofExecutableAt:))
        guard ConnectionPolicy.accepts(peerUID: connection.effectiveUserIdentifier, consoleUID: ConnectionPolicy.consoleUser(), bundleIdentifier: bundleID) else {
            helperLog.error("rejected pid \(connection.processIdentifier) uid \(connection.effectiveUserIdentifier) bundle \(bundleID ?? "nil", privacy: .public) path \(executable ?? "nil", privacy: .public)")
            return false
        }
        // Gate real do privilégio: a identidade do peer passa a ser verificada
        // pelo kernel contra a assinatura, não pelo Info.plist lido de um
        // caminho que o chamador controla. Precisa vir antes de `resume`.
        connection.setCodeSigningRequirement(HelperPaths.clientCodeSigningRequirement)
        // O requisito de assinatura não reprova aqui: uma conexão que não o
        // satisfaz é invalidada na primeira mensagem. Por isso "pending".
        helperLog.info("accepted pid \(connection.processIdentifier) signature-check pending")
        let token = SessionToken()
        let handler = ConnectionHandler(token: token, sleep: self.sleep, tracker: self.tracker)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = handler
        let pid = connection.processIdentifier
        let ended: @Sendable () -> Void = { [sleep, tracker] in
            if !handler.servedAnyMessage {
                helperLog.error("pid \(pid) closed without serving a message: likely code signing requirement mismatch (app and helper from different builds?)")
            }
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
    private let served = OSAllocatedUnfairLock(initialState: false)

    /// Distingue "app fechou normalmente" de "conexão morreu antes da primeira
    /// mensagem" — o sintoma de um requisito de assinatura não satisfeito.
    var servedAnyMessage: Bool { self.served.withLock { $0 } }

    private func markServed() { self.served.withLock { $0 = true } }

    init(token: SessionToken, sleep: SleepControl, tracker: SessionTracker) {
        self.token = token
        self.sleep = sleep
        self.tracker = tracker
    }

    func version(reply: @escaping (Int) -> Void) {
        self.markServed()
        reply(HelperVersion.current)
    }

    func sleepIsDisabled(reply: @escaping (NSNumber?, NSError?) -> Void) {
        self.markServed()
        Task {
            do { reply(NSNumber(value: try await self.sleep.isDisabled()), nil) }
            catch { reply(nil, Self.bridge(error)) }
        }
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void) {
        self.markServed()
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
}
