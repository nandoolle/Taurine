import Foundation

@objc public protocol HelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    func sleepIsDisabled(reply: @escaping (NSNumber?, NSError?) -> Void)
    func setSleepDisabled(_ disabled: Bool, appPath: String, reply: @escaping (NSError?) -> Void)
}

public enum HelperVersion {
    // Incrementar apenas quando o protocolo ou o comportamento do helper mudar.
    public static let current = 1
}

public enum HelperPaths {
    public static let label = "dev.taurine.helper"
    public static let machService = label
    public static let appBundleIdentifier = "dev.taurine.app"
    public static let teamIdentifier = "6Y9HYL9GKV"
    /// Requisito de assinatura exigido do app pelo helper. Fixo de propósito:
    /// é uma afirmação sobre o binário publicado, não deve ser configurável
    /// por quem compila.
    public static let clientCodeSigningRequirement = """
    identifier "\(appBundleIdentifier)" and anchor apple generic \
    and certificate leaf[subject.OU] = "\(teamIdentifier)"
    """
    public static let installedBinary = "/Library/PrivilegedHelperTools/dev.taurine.helper"
    public static let installedPlist = "/Library/LaunchDaemons/dev.taurine.helper.plist"
    public static let stateDirectory = "/var/db/taurine"
    public static let appPathFile = "/var/db/taurine/app-path"
    public static let versionFile = "/var/db/taurine/helper-version"
    public static let applicationsCopy = "/Applications/Taurine.app"
    public static let bundleBinary = "Contents/Library/LaunchDaemons/dev.taurine.helper"
    public static let bundlePlist = "Contents/Library/LaunchDaemons/dev.taurine.helper.plist"
}
