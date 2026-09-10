import AppKit
import XCTest
@testable import TaurineCore

final class DockPresenceTests: XCTestCase {
    // O app é LSUIElement: sem o opt-in a política tem de continuar accessory,
    // senão o ícone aparece no Dock por padrão.
    func testPolicyIsAccessoryUnlessOptedIn() {
        XCTAssertEqual(DockPresence.policy(showInDock: false), .accessory)
        XCTAssertEqual(DockPresence.policy(showInDock: true), .regular)
    }
}
