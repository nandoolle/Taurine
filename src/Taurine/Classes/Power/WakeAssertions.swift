import Foundation
import IOKit.pwr_mgt

@MainActor
protocol WakePreventing {
    func acquire() throws
    func release() throws
}

@MainActor
final class WakeAssertions: WakePreventing {
    private var identifiers: [IOPMAssertionID] = []

    func acquire() throws {
        guard self.identifiers.isEmpty else { return }
        do {
            for type in [kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertPreventUserIdleDisplaySleep] {
                var identifier: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    type as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    String(localized: "Taurine prevents sleep") as CFString,
                    &identifier
                )
                guard result == kIOReturnSuccess else { throw PowerError.assertionFailed(result) }
                self.identifiers.append(identifier)
            }
        } catch {
            try? self.release()
            throw error
        }
    }

    func release() throws {
        var failed: [IOPMAssertionID] = []
        var failure: IOReturn?
        for identifier in self.identifiers {
            let result = IOPMAssertionRelease(identifier)
            if result != kIOReturnSuccess {
                failed.append(identifier)
                failure = result
            }
        }
        self.identifiers = failed
        if let failure { throw PowerError.assertionFailed(failure) }
    }
}
