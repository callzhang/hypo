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
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "HypoMenuBarApp",
            dependencies: ["HypoApp"],
            path: "Sources/HypoMenuBarApp"
        ),
        .testTarget(
            name: "HypoAppTests",
            dependencies: [
                "HypoApp",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoAppTests",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-suppress-warnings"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
