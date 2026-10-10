// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Parrot",
            exclude: [
                // Consumed by build.sh when assembling the .app, not by SwiftPM.
                "Info.plist",
                "Parrot.entitlements",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        // Helper that Claude Code and Codex hooks run. A stub for now.
        .executableTarget(
            name: "parrot-agent-hook",
            path: "AgentHook"
        ),
        .testTarget(
            name: "ParrotTests",
            dependencies: ["Parrot"],
            path: "ParrotTests",
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
