import Foundation
import TaurineShared

enum PowerError: LocalizedError {
    case cancelled
    case commandFailed(String)
    case unreadableState
    case verificationFailed
    case assertionFailed(Int32)
    case helperNotInstalled
    case helperOutdated
    case helperUnavailable

    var errorDescription: String? {
        switch self {
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
        case .helperNotInstalled:
            return String(localized: "Taurine could not set up sleep control.")
        case .helperOutdated:
            return String(localized: "Taurine needs to be restarted to finish updating.")
        case .helperUnavailable:
            return String(localized: "Taurine could not control this Mac's sleep setting.")
        }
    }
}

@MainActor
protocol PowerSettings {
    func sleepIsDisabled() async throws -> Bool
    func setSleepDisabled(_ disabled: Bool) async throws
}
