import Foundation

@objc public protocol HelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    func sleepIsDisabled(reply: @escaping (NSNumber?, NSError?) -> Void)
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void)
}

public enum HelperVersion {
    // Incrementar apenas quando o protocolo ou o comportamento do helper mudar.
    public static let current = 2
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
    /// Nome do plist dentro de `Contents/Library/LaunchDaemons`, como o
    /// `SMAppService.daemon(plistName:)` espera.
    public static let daemonPlistName = "dev.taurine.helper.plist"
    public static let stateDirectory = "/var/db/taurine"

    /// Caminhos da instalação anterior a `SMAppService`. Mantidos apenas para
    /// detectar e desinstalar o daemon legado, que usa o mesmo Label e
    /// MachService e colidiria com o registro novo.
    public static let legacyBinary = "/Library/PrivilegedHelperTools/dev.taurine.helper"
    public static let legacyPlist = "/Library/LaunchDaemons/dev.taurine.helper.plist"
}
