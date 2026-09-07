import Darwin
import Foundation
import SystemConfiguration
import TaurineShared

enum ConnectionPolicy {
    static func accepts(peerUID: uid_t, consoleUID: uid_t?, bundleIdentifier: String?) -> Bool {
        guard let consoleUID, consoleUID != 0, peerUID == consoleUID else { return false }
        return bundleIdentifier == HelperPaths.appBundleIdentifier
    }

    static func consoleUser() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
        return uid
    }

    static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN) é macro parentetizada e não é
        // importada pelo Swift; reproduzimos o valor do <sys/proc_info.h>.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(validatingCString: buffer)
    }

    static func bundleIdentifier(ofExecutableAt path: String) -> String? {
        var candidate = path
        while candidate != "/" {
            if candidate.hasSuffix(".app") { return Bundle(path: candidate)?.bundleIdentifier }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }
}
