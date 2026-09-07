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
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = ConnectionHandler(id: id, sleep: self.sleep, tracker: self.tracker)
        let ended: @Sendable () -> Void = { [sleep, tracker] in
            Task { await Self.connectionEnded(id, sleep: sleep, tracker: tracker) }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        connection.resume()
        return true
    }

    // Fallback de segurança: o app morreu sem desativar. Cobre crash, SIGKILL e logout.
    private static func connectionEnded(_ id: ObjectIdentifier, sleep: SleepControl, tracker: SessionTracker) async {
        guard await tracker.end(id) else { return }
        if (try? await sleep.isDisabled()) == true {
            try? await sleep.setDisabled(false)
        }
    }
}

final class ConnectionHandler: NSObject, HelperProtocol, @unchecked Sendable {
    private let id: ObjectIdentifier
    private let sleep: SleepControl
    private let tracker: SessionTracker

    init(id: ObjectIdentifier, sleep: SleepControl, tracker: SessionTracker) {
        self.id = id
        self.sleep = sleep
        self.tracker = tracker
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
            if disabled {
                guard await self.tracker.begin(self.id) else {
                    reply(HelperFailure(code: .busy).nsError)
                    return
                }
            }
            do {
                try await self.sleep.setDisabled(disabled)
                Self.recordAppPath(appPath)
                if !disabled { _ = await self.tracker.end(self.id) }
                reply(nil)
            } catch {
                if disabled { _ = await self.tracker.end(self.id) }
                reply(Self.bridge(error))
            }
        }
    }

    private static func bridge(_ error: Error) -> NSError {
        (error as? HelperFailure ?? HelperFailure(code: .commandFailed, message: error.localizedDescription)).nsError
    }

    private static func recordAppPath(_ path: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: HelperPaths.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data((path + "\n").utf8).write(to: URL(fileURLWithPath: HelperPaths.appPathFile), options: .atomic)
    }
}
