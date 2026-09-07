import Foundation

/// Token de sessão emitido por conexão aceita. Um UUID novo por conexão evita
/// que uma conexão futura reuse a identidade de uma já encerrada.
typealias SessionToken = UUID

actor SessionTracker {
    private var owner: SessionToken?

    func begin(_ id: SessionToken) -> Bool {
        if let owner, owner != id { return false }
        self.owner = id
        return true
    }

    func end(_ id: SessionToken) -> Bool {
        guard self.owner == id else { return false }
        self.owner = nil
        return true
    }

    func isActive(_ id: SessionToken) -> Bool { self.owner == id }
}
