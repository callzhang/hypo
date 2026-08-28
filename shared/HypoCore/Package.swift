// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HypoCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HypoCore",
            targets: ["HypoCore"]
        )
    ],
    targets: [
        .target(
            name: "HypoCore",
            path: "Sources/HypoCore",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ]
)
