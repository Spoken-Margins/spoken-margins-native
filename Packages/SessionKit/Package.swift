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
        .library(name: "SessionKitPocket", targets: ["SessionKitPocket"]),
        .library(name: "SessionKitSpeechFrontEnd", targets: ["SessionKitSpeechFrontEnd"]),
        .library(name: "SessionKitEPUB", targets: ["SessionKitEPUB"]),
        .library(name: "SessionKitFeeds", targets: ["SessionKitFeeds"]),
        .executable(name: "speech-bench", targets: ["SpeechBench"]),
        // Renders the guided tour clip with the bundled Kitten voice (#2051). The app never links it.
        .executable(name: "tour-render", targets: ["TourRender"]),
        // The daily Substack format canary (#2027), run by .github/workflows/substack-canary.yml. The app never links it.
        .executable(name: "substack-canary", targets: ["SubstackCanary"]),
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
        // libbz2 from the Apple SDKs, for the tar.bz2 archives some voices are published in (#2086). A C target
        // rather than a system library, which Xcode can't resolve as a package dependency. Apple platforms only:
        // Linux builds SessionKit without it, and BZip2ArchiveDecompressor says so.
        .target(name: "CBZip2", linkerSettings: [.linkedLibrary("bz2")]),
        .target(
            name: "SessionKit",
            dependencies: [.target(name: "CBZip2")]
        ),
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
                "SessionKitSpeechFrontEnd",
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                )
            ]
        ),
        // Kyutai Pocket TTS on the same onnxruntime (#459). Nothing in the app links it yet.
        .target(
            name: "SessionKitPocket",
            dependencies: [
                "SessionKit",
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                )
            ]
        ),
        // The text front end for the bundled Kitten voice (#849): Foundation only, so it host-tests on Linux too.
        .target(name: "SessionKitSpeechFrontEnd"),
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
        // The canary's verdict rules (#2027), Foundation only so they host-test on Linux; and the canary itself,
        // which reads live Substack pages with the app's parser. Neither is in the app.
        .target(name: "SubstackCanaryCore"),
        .executableTarget(
            name: "SubstackCanary",
            dependencies: ["SessionKit", "SessionKitFeeds", "SubstackCanaryCore"]
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
        // Real-time factor of each bundled narration engine on the Mac (#849).
        .executableTarget(
            name: "SpeechBench",
            dependencies: ["SessionKit", "SessionKitSupertonic"]
        ),
        .executableTarget(
            name: "TourRender",
            dependencies: ["SessionKit", "SessionKitSupertonic"]
        ),
        // Every file a test reads from outside the package, by name (#1387). Not a product: only the tests link it.
        .target(name: "SessionKitTestInputs", path: "Tests/TestInputs"),
        // Tests of the Foundation-only modules. Also runs on Linux (see the end of this file).
        .testTarget(
            name: "SessionKitCoreTests",
            dependencies: [
                "SessionKit",
                "SessionKitPersistence",
                "SessionKitAI",
                "SessionKitEPUB",
                "SessionKitFeeds",
                "SessionKitSpeechFrontEnd",
                "SessionKitTestInputs",
                "SubstackCanaryCore",
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
                "SessionKitPocket",
                "SessionKitEPUB",
                "SessionKitFeeds",
                "ShippedPacketReader",
                "ShippedSessionKit",
                "SessionKitTestInputs",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            // Test fixtures read by path (#filePath), not bundled resources.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "SessionKitTraceTests",
            dependencies: ["SessionKit", "SessionKitPersistence", "SessionKitAI", "SessionKitTestInputs"]
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
    "SessionKitSpeechFrontEnd", "SessionKitTestInputs", "SessionKitCoreTests",
    // The Substack canary (#2027) runs on the VPS runner; "substack-canary" is its product's name.
    "SubstackCanaryCore", "SubstackCanary", "substack-canary",
]
package.targets.removeAll { !linuxTargets.contains($0.name) }
package.products.removeAll { !linuxTargets.contains($0.name) }
package.dependencies = [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
]
package.targets.append(.systemLibrary(name: "SQLite3", path: "Linux/SQLite3", providers: [.apt(["libsqlite3-dev"])]))
for target in package.targets where target.name == "SessionKit" || target.name == "SessionKitFeeds" || target.name == "SessionKitCoreTests" {
    target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}
for target in package.targets where target.name == "SessionKit" {
    // CBZip2 is Apple-only (left out above); its dependency goes with it.
    target.dependencies.removeAll {
        if case .targetItem(name: "CBZip2", _) = $0 { return true }
        return false
    }
}
for target in package.targets where target.name == "SessionKitPersistence" {
    target.dependencies.append("SQLite3")
}
#endif
