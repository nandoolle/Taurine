import Foundation
import TaurineShared

/// Executa AppleScript dentro do próprio app. O prompt de autorização se atribui
/// ao processo que o pede: lançar `/usr/bin/osascript` como subprocesso fazia o
/// diálogo se identificar como "osascript", com ícone genérico.
enum AppleScriptRunner {
    /// A saída imita `CommandOutput` para preservar o contrato injetável do
    /// HelperInstaller, cujos testes substituem este executor.
    static func run(_ source: String) async -> CommandOutput {
        await withCheckedContinuation { continuation in
            // NSAppleScript exige a main thread: não é thread-safe e precisa de
            // um runloop para apresentar o diálogo.
            DispatchQueue.main.async {
                var failure: NSDictionary?
                let value = NSAppleScript(source: source)?.executeAndReturnError(&failure)
                guard let failure else {
                    continuation.resume(returning: CommandOutput(status: 0, text: value?.stringValue ?? ""))
                    return
                }
                let code = failure[NSAppleScript.errorNumber] as? Int ?? 1
                let message = failure[NSAppleScript.errorMessage] as? String ?? ""
                continuation.resume(returning: CommandOutput(status: Int32(code), text: message))
            }
        }
    }
}
