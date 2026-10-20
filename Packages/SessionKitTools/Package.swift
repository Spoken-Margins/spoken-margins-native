// swift-tools-version: 6.0

import PackageDescription

// This repository's developer tools that are built on SessionKit (#1873). They live outside
// Packages/SessionKit so that a project depending on SessionKit resolves only its libraries.
// The app never links them.
let package = Package(
    name: "SessionKitTools",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Checks and renders the daily phone test plan for scripts/daily-phone-plan.
        .executable(name: "phone-plan", targets: ["PhonePlan"]),
        // Mac tool for co-op test packets (#856), run by scripts/sharing_kit.py.
        .executable(name: "coop-packet", targets: ["CoopPacket"])
    ],
    dependencies: [
        .package(path: "../SessionKit")
    ],
    targets: [
        .executableTarget(
            name: "PhonePlan",
            dependencies: [.product(name: "SessionKit", package: "SessionKit")]
        ),
        .executableTarget(
            name: "CoopPacket",
            dependencies: [
                .product(name: "SessionKit", package: "SessionKit"),
                .product(name: "SessionKitAudio", package: "SessionKit"),
                .product(name: "SessionKitPersistence", package: "SessionKit"),
                .product(name: "SessionKitSharing", package: "SessionKit"),
                .product(name: "ShippedPacketReader", package: "SessionKit")
            ],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "CoopPacketTests",
            dependencies: [
                "CoopPacket",
                .product(name: "SessionKit", package: "SessionKit"),
                .product(name: "SessionKitPersistence", package: "SessionKit"),
                .product(name: "SessionKitSharing", package: "SessionKit"),
                .product(name: "ShippedPacketReader", package: "SessionKit")
            ]
        )
    ]
)

#if os(Linux)
// SessionKit builds only its Foundation-only modules on Linux (the end of its Package.swift), so only
// phone-plan builds here. coop-packet speaks with `say` and signs audio with ShazamKit: Mac only.
package.targets.removeAll { $0.name != "PhonePlan" }
package.products.removeAll { $0.name != "phone-plan" }
#endif
