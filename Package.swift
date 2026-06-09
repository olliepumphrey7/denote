// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Denote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Denote", targets: ["Denote"]),
        .executable(name: "DenoteChecks", targets: ["DenoteChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Denote",
            dependencies: ["DenoteCore", "WhisperKit"],
            path: "Sources/Denote",
            exclude: ["EditorAssets"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "DenoteChecks",
            dependencies: ["DenoteCore"],
            path: "Sources/DenoteChecks"
        ),
        .target(
            name: "DenoteCore",
            path: "Sources/DenoteCore"
        )
    ]
)
