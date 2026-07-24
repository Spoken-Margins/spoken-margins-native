// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [
        .iOS("16.7"),
        .macOS(.v15)
    ],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "SessionKitPersistence", targets: ["SessionKitPersistence"]),
        .library(name: "SessionKitAudio", targets: ["SessionKitAudio"]),
        .library(name: "SessionKitAI", targets: ["SessionKitAI"]),
        .library(name: "SessionKitSupertonic", targets: ["SessionKitSupertonic"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            exact: "1.24.2"
        )
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
        .target(
            name: "SessionKitSupertonic",
            dependencies: [
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                )
            ]
        ),
        .testTarget(
            name: "SessionKitTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAudio", "SessionKitAI", "SessionKitSupertonic"]
        ),
        .testTarget(
            name: "SessionKitTraceTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI"]
        )
    ]
)
