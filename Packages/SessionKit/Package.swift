// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "SessionKitPersistence", targets: ["SessionKitPersistence"]),
        .library(name: "SessionKitAudio", targets: ["SessionKitAudio"]),
        .library(name: "SessionKitAI", targets: ["SessionKitAI"])
    ],
    targets: [
        .target(name: "SessionKit"),
        .target(
            name: "SessionKitPersistence",
            dependencies: ["SessionKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SessionKitAudio",
            dependencies: ["SessionKit"]
        ),
        .target(
            name: "SessionKitAI",
            dependencies: ["SessionKit"]
        ),
        .testTarget(
            name: "SessionKitTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI"]
        ),
        .testTarget(
            name: "SessionKitTraceTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI"]
        )
    ]
)
