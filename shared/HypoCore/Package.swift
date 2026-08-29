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
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "HypoCore",
            path: "Sources/HypoCore",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "HypoCoreTests",
            dependencies: [
                "HypoCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoCoreTests"
        )
    ]
)
