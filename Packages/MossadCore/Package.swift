// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MossadCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "MossadCore", targets: ["MossadCore"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.29"),
    ],
    targets: [
        .target(name: "MossadCore", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS])),
            .product(name: "Qwen3ASR", package: "speech-swift", condition: .when(platforms: [.macOS])),
            .product(name: "AudioCommon", package: "speech-swift", condition: .when(platforms: [.macOS])),
        ]),
        .testTarget(name: "MossadCoreTests", dependencies: ["MossadCore"]),
    ]
)
