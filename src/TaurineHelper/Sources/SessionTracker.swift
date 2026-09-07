import Foundation

actor SessionTracker {
    private var owner: ObjectIdentifier?

    func begin(_ id: ObjectIdentifier) -> Bool {
        if let owner, owner != id { return false }
        self.owner = id
        return true
    }

    func end(_ id: ObjectIdentifier) -> Bool {
        guard self.owner == id else { return false }
        self.owner = nil
        return true
    }

    func isActive(_ id: ObjectIdentifier) -> Bool { self.owner == id }
}
