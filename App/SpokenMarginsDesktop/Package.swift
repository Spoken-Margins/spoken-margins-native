// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpokenMarginsDesktop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DesktopCore", targets: ["DesktopCore"]),
        .executable(name: "SpokenMarginsDesktop", targets: ["SpokenMarginsDesktop"])
    ],
    dependencies: [.package(path: "../../Packages/SessionKit")],
    targets: [
        .target(name: "DesktopCore", dependencies: [
            .product(name: "SessionKit", package: "SessionKit"),
            .product(name: "SessionKitPersistence", package: "SessionKit")
        ]),
        .executableTarget(name: "SpokenMarginsDesktop", dependencies: [
            "DesktopCore",
            .product(name: "SessionKitAudio", package: "SessionKit"),
            .product(name: "SessionKitSupertonic", package: "SessionKit")
        ]),
        .testTarget(name: "DesktopCoreTests", dependencies: ["DesktopCore"])
    ]
)
