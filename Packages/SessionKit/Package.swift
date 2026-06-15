// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "SessionKitPersistence", targets: ["SessionKitPersistence"]),
        .library(name: "SessionKitAudio", targets: ["SessionKitAudio"]),
        .library(name: "SessionKitAI", targets: ["SessionKitAI"]),
        .library(name: "SessionKitKokoro", targets: ["SessionKitKokoro"])
    ],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", from: "1.0.11"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
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
            name: "SessionKitKokoro",
            dependencies: [
                "SessionKit",
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
            ]
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
