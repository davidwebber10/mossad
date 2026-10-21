// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MossadCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MossadCore", targets: ["MossadCore"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "MossadCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "MossadCoreTests", dependencies: ["MossadCore"]),
    ]
)
