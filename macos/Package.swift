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
            dependencies: ["HypoApp"],
            path: "Tests/HypoAppTests"
        )
    ]
)
