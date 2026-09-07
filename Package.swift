// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Taurine",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TaurineCore", targets: ["TaurineCore"])],
    targets: [
        .target(name: "TaurineCore", path: "src/Taurine/Classes/Power"),
        .testTarget(name: "TaurineCoreTests", dependencies: ["TaurineCore"]),
    ]
)
