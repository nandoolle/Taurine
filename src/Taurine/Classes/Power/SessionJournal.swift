import Foundation

@MainActor
protocol SessionJournaling {
    func setPending(_ pending: Bool) throws
}

@MainActor
final class SessionJournal: SessionJournaling {
    private let url: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Taurine", isDirectory: true))
    {
        self.url = directory.appendingPathComponent("pending-session")
    }

    func setPending(_ pending: Bool) throws {
        if pending {
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Taurine must restore disablesleep to 0.\n".utf8).write(to: self.url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: self.url.path) {
            try FileManager.default.removeItem(at: self.url)
        }
    }
}
