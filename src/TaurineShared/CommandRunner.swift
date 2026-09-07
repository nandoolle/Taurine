import Foundation

public struct CommandOutput: Sendable {
    public let status: Int32
    public let text: String

    public init(status: Int32, text: String) {
        self.status = status
        self.text = text
    }
}

public enum CommandRunner {
    // Drain the combined pipe while the process runs, so output cannot fill it
    // and deadlock. Authorization happens outside the main thread.
    nonisolated public static func run(_ executable: String, arguments: [String]) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: CommandOutput(
                        status: process.terminationStatus,
                        text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
