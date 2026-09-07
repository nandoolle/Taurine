import Foundation
import TaurineShared

struct SleepControl: Sendable {
    typealias Runner = @Sendable (String, [String]) async throws -> CommandOutput

    private let run: Runner

    init(run: @escaping Runner = { try await CommandRunner.run($0, arguments: $1) }) {
        self.run = run
    }

    func isDisabled() async throws -> Bool {
        let output = try await self.run("/usr/bin/pmset", ["-g"])
        guard output.status == 0 else { throw HelperFailure(code: .commandFailed, message: output.text) }
        return try Self.parseSleepDisabled(output.text)
    }

    func setDisabled(_ disabled: Bool) async throws {
        let output = try await self.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
        guard output.status == 0 else { throw HelperFailure(code: .commandFailed, message: output.text) }
        guard try await self.isDisabled() == disabled else { throw HelperFailure(code: .verificationFailed) }
    }

    static func parseSleepDisabled(_ text: String) throws -> Bool {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.first == "SleepDisabled", fields.count == 2 else { continue }
            if fields[1] == "0" { return false }
            if fields[1] == "1" { return true }
        }
        throw HelperFailure(code: .unreadableState)
    }
}
