import Foundation
import TaurineShared

enum PowerError: LocalizedError {
    case cancelled
    case authorizationRequired
    case commandFailed(String)
    case unreadableState
    case verificationFailed
    case assertionFailed(Int32)
    case helperNotInstalled

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return String(localized: "The Taurine helper is not installed.")
        case .authorizationRequired:
            return String(localized: "Sleep still needs to be restored. Use Restore sleep in the Taurine menu to authorize it, or enable optional one-time authorization in Preferences.")
        case .cancelled:
            return String(localized: "Administrator authorization was cancelled.")
        case let .commandFailed(message):
            return message
        case .unreadableState:
            return String(localized: "Could not read the Mac's sleep setting.")
        case .verificationFailed:
            return String(localized: "The Mac did not confirm the requested sleep setting.")
        case let .assertionFailed(code):
            return String(localized: "Could not update sleep prevention.") + " (\(code))"
        }
    }
}

@MainActor
protocol PowerSettings {
    func sleepIsDisabled() async throws -> Bool
    func setSleepDisabled(_ disabled: Bool) async throws
    func setSleepDisabled(_ disabled: Bool, allowPrompt: Bool) async throws
}

extension PowerSettings {
    func setSleepDisabled(_ disabled: Bool, allowPrompt: Bool) async throws {
        try await self.setSleepDisabled(disabled)
    }
}

@MainActor
final class PMSetController: PowerSettings {
    private let run: (String, [String]) async throws -> CommandOutput
    private let authorizationConfigured: @MainActor () -> Bool

    init(run: @escaping (String, [String]) async throws -> CommandOutput = { try await CommandRunner.run($0, arguments: $1) }, authorizationConfigured: @escaping @MainActor () -> Bool = { PermanentAuthorization.isConfigured }) {
        self.run = run
        self.authorizationConfigured = authorizationConfigured
    }

    func sleepIsDisabled() async throws -> Bool {
        let output = try await self.run("/usr/bin/pmset", ["-g"])
        guard output.status == 0 else { throw PowerError.commandFailed(output.text) }
        return try Self.parseSleepDisabled(output.text)
    }

    nonisolated static func parseSleepDisabled(_ text: String) throws -> Bool {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.first == "SleepDisabled", fields.count == 2 else { continue }
            if fields[1] == "0" { return false }
            if fields[1] == "1" { return true }
        }
        throw PowerError.unreadableState
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await self.setSleepDisabled(disabled, allowPrompt: true)
    }

    func setSleepDisabled(_ disabled: Bool, allowPrompt: Bool) async throws {
        let output = try await self.run(
            "/usr/bin/sudo", ["-n", "-k", "--", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        )
        if output.status != 0 {
            guard !self.authorizationConfigured() else { throw PowerError.commandFailed(output.text) }
            guard allowPrompt else { throw PowerError.authorizationRequired }
            // Only a fixed command and boolean value enter the privileged script.
            let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
            let authorized = try await self.run("/usr/bin/osascript", ["-e", script])
            guard authorized.status == 0 else {
                if authorized.text.contains("(-128)") { throw PowerError.cancelled }
                throw PowerError.commandFailed(authorized.text)
            }
        }
    }
}
