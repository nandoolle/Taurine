import Darwin
import Foundation
import TaurineShared

@MainActor
final class PermanentAuthorization {
    static var rulePath: String { "/private/etc/sudoers.d/taurine-\(getuid())" }

    // Only root can create this marker in sudoers.d. Execution still checks the
    // actual policy on every command, ignoring cached sudo credentials.
    static var isConfigured: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: self.rulePath) else { return false }
        return attrs[.type] as? FileAttributeType == .typeRegular
            && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0
            && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o440
    }

    nonisolated static func rule(for uid: UInt32) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"
    }

    nonisolated static func installationScript(uid: UInt32, removing: Bool = false) -> String {
        // No paths, user names, arguments or script files supplied by a caller
        // are executed as root. Only a numeric UID and a fixed action vary.
        let operation = removing ? #"""
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            [ ! -L "$destination" ] && /usr/bin/cmp -s "$temporary" "$destination" || exit 1
            /bin/rm "$destination"
        fi
        /usr/sbin/visudo -c
        """# : #"""
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            [ ! -L "$destination" ] && /usr/bin/cmp -s "$temporary" "$destination" || exit 1
            [ "$(/usr/bin/stat -f '%u:%Lp' "$destination")" = '0:440' ] || exit 1
        else
            /bin/mv "$temporary" "$destination"
        fi
        if ! validation=$(/usr/sbin/visudo -c 2>&1); then
            /bin/rm "$destination"
            printf '%s\n' "$validation" >&2
            exit 1
        fi
        if ! printf '%s\n' "$validation" | /usr/bin/grep -F "/sudoers.d/taurine-\#(uid):" >/dev/null; then
            /bin/rm "$destination"
            printf '%s\n' 'The system sudo configuration does not include the Taurine permission.' >&2
            exit 1
        fi
        """#
        return #"""
        set -eu
        export LC_ALL=C
        umask 077
        directory=/private/etc/sudoers.d
        destination="$directory/taurine-\#(uid)"
        [ ! -L "$directory" ] || exit 1
        if [ ! -d "$directory" ]; then
            /usr/bin/install -d -o root -g wheel -m 0755 "$directory"
        fi
        [ "$(/usr/bin/stat -f '%u' "$directory")" = '0' ] || exit 1
        mode=$(/usr/bin/stat -f '%Lp' "$directory")
        [ "$((0$mode & 022))" -eq 0 ] || exit 1
        /usr/sbin/visudo -c >/dev/null
        temporary=$(/usr/bin/mktemp "$directory/.taurine-\#(uid).XXXXXX")
        trap '/bin/rm -f "$temporary"' EXIT
        printf '%s\n' '#\#(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0' > "$temporary"
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 0440 "$temporary"
        /usr/sbin/visudo -cf "$temporary" >/dev/null
        \#(operation)
        """#
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

    func configure(removing: Bool = false) async throws {
        let script = Self.installationScript(uid: getuid(), removing: removing)
        let output = try await CommandRunner.run("/usr/bin/osascript", arguments: ["-e", Self.appleScript(for: script)])
        if output.text == "TAURINE_AUTH_CANCELLED" { throw PowerError.cancelled }
        guard output.status == 0 else { throw PowerError.commandFailed(output.text) }
        guard Self.isConfigured != removing else { throw PowerError.authorizationRequired }
    }
}
