// swift-tools-version: 6.0
// Runs the app's own PDF extractor over the C1 corpus on macOS. See README.md.
// The app's source files are copied in by sync-app-sources.sh, not edited here.

import PackageDescription

let package = Package(
    name: "C1Extract",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "c1-extract",
            path: "Sources/c1-extract",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
