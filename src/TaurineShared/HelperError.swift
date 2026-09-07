import Foundation

public enum HelperError: Int, Sendable, Equatable {
    case busy = 1
    case unauthorized = 2
    case commandFailed = 3
    case unreadableState = 4
    case verificationFailed = 5

    public static let domain = "dev.taurine.helper"
}

public struct HelperFailure: Error, Sendable, Equatable {
    public let code: HelperError
    public let message: String?

    private static let messageKey = "dev.taurine.helper.message"

    public init(code: HelperError, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public init?(_ error: NSError) {
        guard error.domain == HelperError.domain, let code = HelperError(rawValue: error.code) else { return nil }
        self.code = code
        self.message = error.userInfo[Self.messageKey] as? String
    }

    public var nsError: NSError {
        var info: [String: Any] = [:]
        if let message { info[Self.messageKey] = message }
        return NSError(domain: HelperError.domain, code: self.code.rawValue, userInfo: info)
    }
}
