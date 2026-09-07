import Foundation

/// Token de sessão emitido por conexão aceita. Um UUID novo por conexão evita
/// que uma conexão futura reuse a identidade de uma já encerrada.
typealias SessionToken = UUID

/// Distingue aquisição nova de reafirmação do dono atual: só quem adquiriu
/// agora pode reverter o `disablesleep` no rollback.
enum SessionAcquisition: Equatable { case acquired, alreadyOwner, busy }

actor SessionTracker {
    private var owner: SessionToken?

    func begin(_ id: SessionToken) -> SessionAcquisition {
        if let owner {
            return owner == id ? .alreadyOwner : .busy
        }
        self.owner = id
        return .acquired
    }

    func end(_ id: SessionToken) -> Bool {
        guard self.owner == id else { return false }
        self.owner = nil
        return true
    }

    func isActive(_ id: SessionToken) -> Bool { self.owner == id }
}
