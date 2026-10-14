// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TycoonCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TycoonCore", targets: ["TycoonCore"]),
        .executable(name: "tycoon-sim", targets: ["TycoonSim"]),
    ],
    targets: [
        .target(name: "TycoonCore"),
        .executableTarget(name: "TycoonSim", dependencies: ["TycoonCore"]),
        .testTarget(name: "TycoonCoreTests", dependencies: ["TycoonCore"]),
    ]
)
