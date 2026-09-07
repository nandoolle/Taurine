import Darwin
import Foundation
import TaurineShared

enum BootstrapOutcome: Equatable { case serving, uninstalled }

struct BootstrapEnvironment: Sendable {
    var fileExists: @Sendable (String) -> Bool
    var isOnRootVolume: @Sendable (String) -> Bool
    var readAppPath: @Sendable () -> String?
    var removeItem: @Sendable (String) async throws -> Void
    var bootout: @Sendable () async throws -> Void

    static let live = BootstrapEnvironment(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        isOnRootVolume: { RootVolume.isOnRootVolume($0) },
        readAppPath: {
            guard let data = FileManager.default.contents(atPath: HelperPaths.appPathFile) else { return nil }
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        },
        removeItem: { try FileManager.default.removeItem(atPath: $0) },
        bootout: {
            _ = try await CommandRunner.run("/bin/launchctl", arguments: ["bootout", "system/\(HelperPaths.label)"])
        }
    )
}

enum Bootstrap {
    static func shouldUninstall(appPathExists: Bool, applicationsCopyExists: Bool, onRootVolume: Bool) -> Bool {
        !appPathExists && !applicationsCopyExists && onRootVolume
    }

    static func run(sleep: SleepControl, environment env: BootstrapEnvironment) async -> BootstrapOutcome {
        // Regra de negócio: no boot o Taurine está sempre desligado.
        if (try? await sleep.isDisabled()) == true {
            try? await sleep.setDisabled(false)
        }
        guard let appPath = env.readAppPath() else { return .serving }
        let uninstall = self.shouldUninstall(
            appPathExists: env.fileExists(appPath),
            applicationsCopyExists: env.fileExists(HelperPaths.applicationsCopy),
            onRootVolume: env.isOnRootVolume(appPath)
        )
        guard uninstall else { return .serving }
        for path in [HelperPaths.installedBinary, HelperPaths.installedPlist, HelperPaths.stateDirectory] {
            try? await env.removeItem(path)
        }
        // bootout por último: encerra este processo.
        try? await env.bootout()
        return .uninstalled
    }
}

enum RootVolume {
    static func isOnRootVolume(
        _ path: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fileSystemID: (String) -> UInt64? = Self.liveFileSystemID
    ) -> Bool {
        var candidate = path
        while candidate != "/", !exists(candidate) {
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.isEmpty { candidate = "/" }
        }
        guard let root = fileSystemID("/"), let ancestor = fileSystemID(candidate) else { return false }
        return root == ancestor
    }

    static func liveFileSystemID(_ path: String) -> UInt64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return (UInt64(UInt32(bitPattern: info.f_fsid.val.0)) << 32) | UInt64(UInt32(bitPattern: info.f_fsid.val.1))
    }
}
