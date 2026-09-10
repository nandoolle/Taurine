import Darwin
import Foundation
import TaurineShared

enum HelperInstallStatus: Equatable { case installed, missing }

@MainActor
final class HelperInstaller {
    private let fileExists: (String) -> Bool
    private let run: (String, [String]) async throws -> CommandOutput

    init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        run: @escaping (String, [String]) async throws -> CommandOutput = { _, arguments in
            await AppleScriptRunner.run(arguments.count > 1 ? arguments[1] : "")
        }
    ) {
        self.fileExists = fileExists
        self.run = run
    }

    static func status(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> HelperInstallStatus {
        fileExists(HelperPaths.installedBinary) && fileExists(HelperPaths.installedPlist) ? .installed : .missing
    }

    func status() -> HelperInstallStatus { Self.status(fileExists: self.fileExists) }

    func install(bundlePath: String) async throws {
        try await self.runPrivileged(Self.installationScript(bundlePath: bundlePath, uid: getuid()))
        guard self.status() == .installed else { throw PowerError.helperNotInstalled }
    }

    func remove() async throws {
        try await self.runPrivileged(Self.removalScript())
        guard self.status() == .missing else { throw PowerError.commandFailed(String(localized: "The Taurine helper could not be removed.")) }
    }

    private func runPrivileged(_ script: String) async throws {
        let output = try await self.run("/usr/bin/osascript", ["-e", Self.appleScript(for: script)])
        if output.text == "TAURINE_AUTH_CANCELLED" { throw PowerError.cancelled }
        guard output.status == 0 else { throw PowerError.commandFailed(output.text) }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func installationScript(bundlePath: String, uid: UInt32) -> String {
        let binary = self.shellQuote(bundlePath + "/" + HelperPaths.bundleBinary)
        let plist = self.shellQuote(bundlePath + "/" + HelperPaths.bundlePlist)
        let app = self.shellQuote(bundlePath)
        // The recorded helper-version is informational only: compatibility is
        // decided by the XPC `version()` call.
        return """
        set -eu
        export LC_ALL=C
        umask 022
        [ -f \(binary) ] || { echo 'helper binary missing from app bundle' >&2; exit 1; }
        [ -f \(plist) ] || { echo 'helper plist missing from app bundle' >&2; exit 1; }
        /bin/launchctl bootout system/\(HelperPaths.label) 2>/dev/null || true
        /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 0755 \(binary) \(HelperPaths.installedBinary)
        /usr/bin/install -o root -g wheel -m 0644 \(plist) \(HelperPaths.installedPlist)
        /usr/bin/install -d -o root -g wheel -m 0700 \(HelperPaths.stateDirectory)
        printf '%s\\n' \(app) > \(HelperPaths.appPathFile)
        printf '%s\\n' '\(HelperVersion.current)' > \(HelperPaths.versionFile)
        /bin/rm -f /private/etc/sudoers.d/taurine-\(uid)
        /bin/launchctl bootstrap system \(HelperPaths.installedPlist)
        """
    }

    nonisolated static func removalScript() -> String {
        """
        set -u
        export LC_ALL=C
        /usr/bin/pmset -a disablesleep 0 || true
        /bin/launchctl bootout system/\(HelperPaths.label) 2>/dev/null || true
        /bin/rm -f \(HelperPaths.installedBinary) \(HelperPaths.installedPlist)
        /bin/rm -rf \(HelperPaths.stateDirectory)
        """
    }

    nonisolated static func appleScript(for shellScript: String) -> String {
        let quoted = shellScript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        try
            do shell script "\(quoted)" with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "TAURINE_AUTH_CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
    }
}
