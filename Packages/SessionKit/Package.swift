// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15)
    ],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "SessionKitPersistence", targets: ["SessionKitPersistence"]),
        .library(name: "SessionKitAudio", targets: ["SessionKitAudio"]),
        .library(name: "SessionKitSharing", targets: ["SessionKitSharing"]),
        .library(name: "SessionKitAI", targets: ["SessionKitAI"]),
        .library(name: "SessionKitSupertonic", targets: ["SessionKitSupertonic"]),
        .library(name: "SessionKitEPUB", targets: ["SessionKitEPUB"]),
        .library(name: "SessionKitFeeds", targets: ["SessionKitFeeds"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            exact: "1.24.2"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
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
            name: "SessionKitSharing",
            dependencies: [
                "SessionKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
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
        .target(
            name: "SessionKitEPUB",
            dependencies: [
                "SessionKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .target(
            name: "SessionKitFeeds",
            dependencies: ["SessionKit"]
        ),
        // The last shipped build's packet reader, frozen for tests (scripts/freeze-shipped-reader.sh, #317).
        // No product exposes these, so the app never links them.
        .target(name: "ShippedSessionKit", path: "Tests/ShippedReader/SessionKit"),
        .target(
            name: "ShippedSessionKitSharing",
            dependencies: [
                "ShippedSessionKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/ShippedReader/SessionKitSharing"
        ),
        .target(
            name: "ShippedPacketReader",
            dependencies: ["ShippedSessionKit", "ShippedSessionKitSharing"],
            path: "Tests/ShippedReader/Reader"
        ),
        .testTarget(
            name: "SessionKitTests",
            dependencies: [
                "SessionKit",
                "SessionKitPersistence",
                "SessionKitAudio",
                "SessionKitSharing",
                "SessionKitAI",
                "SessionKitSupertonic",
                "SessionKitEPUB",
                "SessionKitFeeds",
                "ShippedPacketReader",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "SessionKitTraceTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI"]
        )
    ]
)
