// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HypoiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HypoiOS",
            targets: ["HypoiOS"]
        )
    ],
    dependencies: [
        .package(path: "../HypoCore"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "HypoiOS",
            dependencies: [
                .product(name: "HypoCore", package: "HypoCore")
            ],
            path: "Sources/HypoiOS"
        ),
        .testTarget(
            name: "HypoiOSTests",
            dependencies: [
                "HypoiOS",
                .product(name: "HypoCore", package: "HypoCore"),
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoiOSTests"
        )
    ]
)
