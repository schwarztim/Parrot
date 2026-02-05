// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Parrot",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "ParrotTests",
            dependencies: ["Parrot"],
            path: "ParrotTests"
        ),
    ]
)
