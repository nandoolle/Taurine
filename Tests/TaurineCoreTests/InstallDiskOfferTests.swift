import XCTest
@testable import TaurineCore

final class InstallDiskOfferTests: XCTestCase {
    func testOffersEjectForTaurineVolumeWhenInstalled() {
        XCTAssertEqual(
            InstallDiskOffer.volumeToEject(
                bundlePath: "/Applications/Taurine.app",
                mountedVolumes: ["/", "/Volumes/Taurine 0.3.0"]
            ),
            "/Volumes/Taurine 0.3.0"
        )
    }

    // Ejetar o volume de onde o binário roda arrancaria o próprio app.
    func testNoOfferWhenRunningFromTheDiskImage() {
        XCTAssertNil(InstallDiskOffer.volumeToEject(
            bundlePath: "/Volumes/Taurine 0.3.0/Taurine.app",
            mountedVolumes: ["/", "/Volumes/Taurine 0.3.0"]
        ))
    }

    func testIgnoresUnrelatedVolumes() {
        XCTAssertNil(InstallDiskOffer.volumeToEject(
            bundlePath: "/Applications/Taurine.app",
            mountedVolumes: ["/", "/Volumes/Backup", "/Volumes/Time Machine"]
        ))
    }

    func testIgnoresRootAndEmptyVolumeList() {
        XCTAssertNil(InstallDiskOffer.volumeToEject(bundlePath: "/Applications/Taurine.app", mountedVolumes: ["/"]))
        XCTAssertNil(InstallDiskOffer.volumeToEject(bundlePath: "/Applications/Taurine.app", mountedVolumes: []))
    }

    // Prefixo "Taurine" cobre "Taurine 0.3.0", "Taurine 0.4.0" e o volume sem
    // versão, sem depender da versão publicada.
    func testMatchesAnyTaurineVolumeName() {
        for name in ["Taurine", "Taurine 0.3.0", "Taurine 1.0"] {
            XCTAssertEqual(
                InstallDiskOffer.volumeToEject(bundlePath: "/Applications/Taurine.app", mountedVolumes: ["/Volumes/\(name)"]),
                "/Volumes/\(name)",
                "esperava oferta para o volume \(name)"
            )
        }
    }
}
