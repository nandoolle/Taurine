import Foundation
import TaurineShared

@MainActor
protocol HelperProxy: AnyObject {
    func version() async throws -> Int
    func sleepIsDisabled() async throws -> Bool
    func setSleepDisabled(_ disabled: Bool, appPath: String) async throws
    func invalidate()
}

@MainActor
final class XPCHelperProxy: HelperProxy {
    private var connection: NSXPCConnection?

    private func remote() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperPaths.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Only clear the connection that actually died: a replacement may already
        // be live by the time this runs, and the helper watches that one.
        connection.invalidationHandler = { [weak self, invalidated = connection] in
            Task { @MainActor in
                guard self?.connection === invalidated else { return }
                self?.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    // The connection stays alive while the app runs: the helper watches it to revert sleep.
    private func proxy(_ onError: @escaping (Error) -> Void) -> HelperProtocol? {
        self.remote().remoteObjectProxyWithErrorHandler { _ in onError(PowerError.helperUnavailable) } as? HelperProtocol
    }

    func version() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = self.proxy({ continuation.resume(throwing: $0) }) else { return continuation.resume(throwing: PowerError.helperUnavailable) }
            proxy.version { continuation.resume(returning: $0) }
        }
    }

    func sleepIsDisabled() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = self.proxy({ continuation.resume(throwing: $0) }) else { return continuation.resume(throwing: PowerError.helperUnavailable) }
            proxy.sleepIsDisabled { value, error in
                if let error { return continuation.resume(throwing: error) }
                guard let value else { return continuation.resume(throwing: PowerError.unreadableState) }
                continuation.resume(returning: value.boolValue)
            }
        }
    }

    func setSleepDisabled(_ disabled: Bool, appPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = self.proxy({ continuation.resume(throwing: $0) }) else { return continuation.resume(throwing: PowerError.helperUnavailable) }
            proxy.setSleepDisabled(disabled, appPath: appPath) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func invalidate() {
        self.connection?.invalidate()
        self.connection = nil
    }
}

@MainActor
final class HelperPowerSettings: PowerSettings {
    private let proxy: HelperProxy
    private let appPath: () -> String

    // The default is built in the body: default argument expressions are evaluated off the MainActor.
    init(proxy: HelperProxy? = nil, appPath: @escaping () -> String = { Bundle.main.bundlePath }) {
        self.proxy = proxy ?? XPCHelperProxy()
        self.appPath = appPath
    }

    func sleepIsDisabled() async throws -> Bool {
        try await self.ensureCompatible()
        return try await self.translating { try await self.proxy.sleepIsDisabled() }
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await self.ensureCompatible()
        try await self.translating { try await self.proxy.setSleepDisabled(disabled, appPath: self.appPath()) }
    }

    private func ensureCompatible() async throws {
        let version = try await self.translating { try await self.proxy.version() }
        guard version == HelperVersion.current else { throw PowerError.helperOutdated }
    }

    private func translating<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as PowerError {
            throw error
        } catch {
            guard let failure = HelperFailure(error as NSError) else { throw PowerError.helperUnavailable }
            throw Self.powerError(for: failure)
        }
    }

    private static func powerError(for failure: HelperFailure) -> PowerError {
        switch failure.code {
        case .unreadableState: return .unreadableState
        case .verificationFailed: return .verificationFailed
        case .commandFailed: return .commandFailed(failure.message ?? String(localized: "Could not update sleep prevention."))
        case .busy: return .commandFailed(String(localized: "Another Taurine session is already active."))
        case .unauthorized: return .commandFailed(String(localized: "The Taurine helper refused the request."))
        }
    }
}
