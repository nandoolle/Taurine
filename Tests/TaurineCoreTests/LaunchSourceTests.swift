import AppKit
import XCTest
@testable import TaurineCore

final class LaunchSourceTests: XCTestCase {
    // Duplo clique comum: a chave não vem no userInfo.
    func testMissingKeyCountsAsUserLaunch() {
        XCTAssertEqual(LaunchSource.from(launchUserInfo: nil), .user)
        XCTAssertEqual(LaunchSource.from(launchUserInfo: [:]), .user)
    }

    func testDefaultLaunchIsUser() {
        XCTAssertEqual(
            LaunchSource.from(launchUserInfo: [NSApplication.launchIsDefaultUserInfoKey: true]),
            .user
        )
    }

    // Item de login, estado restaurado, abrir arquivo: nenhum é um pedido do
    // usuário pelo app, e nenhum deve trazer as Preferências à frente.
    func testNonDefaultLaunchIsAutomatic() {
        XCTAssertEqual(
            LaunchSource.from(launchUserInfo: [NSApplication.launchIsDefaultUserInfoKey: false]),
            .automatic
        )
    }
}
