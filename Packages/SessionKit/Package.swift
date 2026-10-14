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
        .library(name: "SessionKitFeeds", targets: ["SessionKitFeeds"]),
        // Mac tool for co-op test packets (#856). The app never links it.
        .executable(name: "coop-packet", targets: ["CoopPacket"]),
        // The last shipped build's packet reader, for the app's own test bundle only (#1039): it
        // reads the packet the real app exporter writes. The app target never links it.
        .library(name: "ShippedPacketReader", targets: ["ShippedPacketReader"])
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
                "SessionKit",
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
        // Only the ShippedPacketReader product exposes them, and only the app's test bundle links it.
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
        .executableTarget(
            name: "CoopPacket",
            dependencies: ["SessionKit", "SessionKitAudio", "SessionKitPersistence", "SessionKitSharing", "ShippedPacketReader"],
            exclude: ["README.md"]
        ),
        // Tests of the Foundation-only modules. Also runs on Linux (see the end of this file).
        .testTarget(
            name: "SessionKitCoreTests",
            dependencies: [
                "SessionKit",
                "SessionKitPersistence",
                "SessionKitAI",
                "SessionKitEPUB",
                "SessionKitFeeds",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        // Tests that need Apple frameworks (AVFoundation, ShazamKit, onnxruntime). Mac only.
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
                "ShippedSessionKit",
                "CoopPacket",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            // Test fixtures read by path (#filePath), not bundled resources.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "SessionKitTraceTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI"]
        )
    ]
)

#if os(Linux)
// Linux (cloud sessions and the ubuntu CI job) builds only the Foundation-only modules and
// their tests. Everything else needs Apple frameworks, so it is left out by allowlist: a new
// target stays Mac-only until it is added here. SessionKitTraceTests uses XCTExpectFailure,
// which Linux XCTest lacks. CryptoKit comes from swift-crypto (same API,
// module `Crypto`), and SQLite3 from a system-library module over libsqlite3.
let linuxTargets: Set<String> = [
    "SessionKit", "SessionKitPersistence", "SessionKitAI", "SessionKitEPUB", "SessionKitFeeds",
    "SessionKitCoreTests",
]
package.targets.removeAll { !linuxTargets.contains($0.name) }
package.products.removeAll { !linuxTargets.contains($0.name) }
package.dependencies = [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
]
package.targets.append(.systemLibrary(name: "SQLite3", path: "Linux/SQLite3", providers: [.apt(["libsqlite3-dev"])]))
for target in package.targets where target.name == "SessionKit" || target.name == "SessionKitCoreTests" {
    target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}
for target in package.targets where target.name == "SessionKitPersistence" {
    target.dependencies.append("SQLite3")
}
#endif
