import Foundation
import TaurineShared

enum Bootstrap {
    /// Regra de negócio: no boot o Taurine está sempre desligado.
    ///
    /// Com `SMAppService` não há auto-desinstalação a fazer — o daemon roda de
    /// dentro do bundle, então um app apagado simplesmente não sobe.
    static func run(sleep: SleepControl) async {
        // Estado ilegível conta como desativado: o revert de boot é incondicional.
        if (try? await sleep.isDisabled()) != false {
            try? await sleep.setDisabled(false)
        }
    }
}
