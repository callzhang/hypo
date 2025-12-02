// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HypoApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "HypoApp",
            targets: ["HypoApp"]
        ),
        .executable(
            name: "HypoMenuBar",
            targets: ["HypoMenuBarApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "HypoApp",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/HypoApp"
        ),
        .executableTarget(
            name: "HypoMenuBarApp",
            dependencies: ["HypoApp"],
            path: "Sources/HypoMenuBarApp"
        ),
        .testTarget(
            name: "HypoAppTests",
            dependencies: ["HypoApp"],
            path: "Tests/HypoAppTests"
        )
    ]
)
