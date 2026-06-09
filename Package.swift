// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EphemeralNotes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EphemeralNotes", targets: ["EphemeralNotes"]),
        .executable(name: "EphemeralNotesChecks", targets: ["EphemeralNotesChecks"])
    ],
    targets: [
        .executableTarget(
            name: "EphemeralNotes",
            dependencies: ["EphemeralNotesCore"],
            path: "Sources/EphemeralNotes",
            exclude: ["EditorAssets"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "EphemeralNotesChecks",
            dependencies: ["EphemeralNotesCore"],
            path: "Sources/EphemeralNotesChecks"
        ),
        .target(
            name: "EphemeralNotesCore",
            path: "Sources/EphemeralNotesCore"
        )
    ]
)
