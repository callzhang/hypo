// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "HypoApp",
            dependencies: [
            ],
            path: "Sources/HypoApp",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "HypoMenuBarApp",
            dependencies: ["HypoApp"],
            path: "Sources/HypoMenuBarApp",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "HypoAppTests",
            dependencies: [
                "HypoApp",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoAppTests",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
