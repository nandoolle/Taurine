// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Taurine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaurineCore", targets: ["TaurineCore"]),
        .executable(name: "dev.taurine.helper", targets: ["TaurineHelper"]),
    ],
    targets: [
        .target(name: "TaurineShared", path: "src/TaurineShared"),
        .target(name: "TaurineCore", dependencies: ["TaurineShared"], path: "src/Taurine/Classes/Power"),
        .executableTarget(name: "TaurineHelper", dependencies: ["TaurineShared"], path: "src/TaurineHelper/Sources"),
        .testTarget(name: "TaurineSharedTests", dependencies: ["TaurineShared"]),
        .testTarget(name: "TaurineCoreTests", dependencies: ["TaurineCore"]),
        .testTarget(name: "TaurineHelperTests", dependencies: ["TaurineHelper"]),
    ]
)
