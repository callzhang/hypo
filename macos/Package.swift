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
        // swift-testing is part of the toolchain from Swift 6 on, and the
        // standalone package's 0.x tags no longer exist -- depending on it here
        // made every push fail at dependency resolution.
        .package(path: "../shared/HypoCore")
    ],
    targets: [
        .target(
            name: "HypoApp",
            dependencies: [
                .product(name: "HypoCore", package: "HypoCore")
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
                "HypoApp"
            ],
            path: "Tests/HypoAppTests",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
