// swift-tools-version: 6.0
// Renders text with the app's Phonon runtime on a Mac, to measure what it does with PDF text. See research/C1/formula/README.md.
import PackageDescription

let package = Package(
    name: "PhononProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/gradium-ai/xn-ptts", exact: "0.4.2")],
    targets: [
        .executableTarget(
            name: "phonon-probe",
            dependencies: [.product(name: "ptts", package: "xn-ptts")],
            path: "Sources/phonon-probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
